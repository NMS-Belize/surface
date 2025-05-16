-- CREATE OR REPLACE FUNCTION is_daylight_hour(
--     hour integer,
--     day_of_year integer,  -- (1-366)
--     latitude float,  -- Latitude in decimal degrees
--     longitude float,  -- Longitude in decimal degrees
--     tz_offset float   -- Timezone offset from UTC (e.g., -5 for EST)
-- ) RETURNS boolean AS $$
-- DECLARE
--     solar_declination float;
--     latitude_radians float;
--     sunset_hour_angle float;  -- Sunset hour angle (radians)
--     daylight_duration float;
--     solar_noon float;
--     sunrise_hour float;
--     sunset_hour float;
-- BEGIN
--     latitude_radians := PI() / 180 * latitude;
    
--     solar_declination := 0.409 * SIN((2 * PI() / 365 * day_of_year) - 1.39);
--     sunset_hour_angle := ACOS(-TAN(latitude_radians) * TAN(solar_declination));
--     daylight_duration := 24 / PI() * sunset_hour_angle;
--     solar_noon := 12 - (tz_offset * 15 - longitude) / 15;
--     sunrise_hour := solar_noon - daylight_duration / 2;
--     sunset_hour := solar_noon + daylight_duration / 2;

--     RETURN (hour >= sunrise_hour AND hour < sunset_hour)
-- END;
-- $$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS as_net_longwave_radiation(double precision,double precision,double precision,double precision,double precision,double precision,integer);
DROP FUNCTION IF EXISTS as_net_radiation(double precision,double precision,double precision,double precision,double precision,double precision,integer);
-- Allen et al. (1998), FAO-56 (Equation 21).
CREATE OR REPLACE FUNCTION extraterrestrial_radiation(
    D_r float,                     -- Dimensionless (inverse relative Earth-Sun distance) [FAO-56 Eq.23]
    omega_s float,                 -- Radians (sunset hour angle) [FAO-56 Eq.25]
    phi float,                     -- Radians (latitude) 
    delta float,                   -- Radians (solar declination) [FAO-56 Eq.24]
    G_sc float DEFAULT 0.0820      -- MJ/m²/min (solar constant) 
) RETURNS float AS $$              -- MJ/m²/day (daily extraterrestrial radiation)
DECLARE
    Ra float;                      -- MJ/m²/day (extraterrestrial radiation)
BEGIN
    Ra := ((24 * 60 )/ PI()) * G_sc * D_r * (
        omega_s * SIN(phi) * SIN(delta) + COS(phi) * COS(delta) * SIN(omega_s)
    );
    RETURN Ra;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 37).
CREATE OR REPLACE FUNCTION clearsky_radiation(
    R_a float,                     -- MJ/m²/day (extraterrestrial radiation)
    z float                        -- m (station elevation above sea level)
) RETURNS float AS $$              -- MJ/m²/day (clear-sky solar radiation)
DECLARE
    R_so float;                    -- MJ/m²/day (clear-sky solar radiation)
BEGIN
    R_so := R_a * (0.75 + (2 * 10^(-5)) * z);
    RETURN R_so;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 11).

CREATE OR REPLACE FUNCTION saturation_vapour_pressure(
    t float                        -- °C (air temperature)
) RETURNS float AS $$              -- kPa (saturation vapour pressure)
DECLARE
    e_t float;                     -- kPa (saturation vapour pressure at temperature t)
BEGIN
    e_t := 0.6108 * EXP((17.27 * t) / (t + 237.3));
    RETURN e_t;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 19)
CREATE OR REPLACE FUNCTION actual_vapour_pressure(
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    rh float                       -- % (relative humidity)
) RETURNS float AS $$              -- kPa (actual vapour pressure)
DECLARE
    e_tmin float;                  -- kPa (saturation vapour pressure at tmin)
    e_tmax float;                  -- kPa (saturation vapour pressure at tmax)
    e_s float;                     -- kPa (mean saturation vapour pressure)
    e_a float;                     -- kPa (actual vapour pressure)
BEGIN
    e_tmin := saturation_vapour_pressure(tmin);
    e_tmax := saturation_vapour_pressure(tmax);
    e_s := (e_tmin + e_tmax)/2;
    e_a := rh/100 * e_s;
    RETURN e_a;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 38).

CREATE OR REPLACE FUNCTION net_shortwave_radiation(
    R_s float,                     -- MJ/m²/day (solar radiation)
    albedo float DEFAULT 0.23      -- dimensionless (surface albedo)
) RETURNS float AS $$              -- MJ/m²/day (net shortwave radiation)
DECLARE
    R_sn float;                    -- MJ/m²/day (net shortwave radiation)
BEGIN
    R_sn := (1 - albedo) * R_s;
    RETURN R_sn;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 Equation 39
CREATE OR REPLACE FUNCTION net_longwave_radiation(
    tmin_k float,                  -- K (daily minimum temperature in Kelvin)
    tmax_k float,                  -- K (daily maximum temperature in Kelvin)
    R_s float,                     -- MJ/m²/day (solar radiation)
    R_so float,                    -- MJ/m²/day (clear-sky radiation)
    e_a float,                     -- kPa (actual vapour pressure)
    sigma float DEFAULT 4.903e-9   -- MJ K⁻⁴ m⁻² day⁻¹ (Stefan-Boltzmann constant)
) RETURNS float AS $$              -- MJ/m²/day (net longwave radiation)
DECLARE
    R_nl float;                    -- MJ/m²/day (net longwave radiation)
BEGIN
    R_nl := sigma * (
        ((POWER(tmax_k, 4) + POWER(tmin_k, 4)) / 2) *
        (0.34 - 0.14 * SQRT(e_a)) *
        (1.35 * (R_s / R_so) - 0.35)
    );
    RETURN R_nl;
END;
$$ LANGUAGE plpgsql;


-- Allen et al. (1998), FAO-56 (Equation 40).
CREATE OR REPLACE FUNCTION net_radiation(
    R_ns float,                    -- MJ/m²/day (net shortwave radiation)
    R_nl float                     -- MJ/m²/day (net longwave radiation)
) RETURNS float AS $$              -- MJ/m²/day (net radiation)
DECLARE
    R_n float;                     -- MJ/m²/day (net radiation)
BEGIN
    R_n := R_ns - R_nl;
    RETURN R_n;
END;
$$ LANGUAGE plpgsql;

-- Net Longwave Radiation for Automatic Stations
CREATE OR REPLACE FUNCTION as_net_longwave_radiation(
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    latitude float,                -- ° (latitude in decimal degrees)
    elevation float,               -- m (station elevation)
    solar_rad float,               -- W/m² (measured solar radiation)
    rh float,                      -- % (relative humidity)
    day_of_year integer            -- 1-366 (day of year)
) RETURNS float AS $$              -- MJ/m²/day (net radiation)
DECLARE
    phi float;                     -- rad (latitude in radians)
    delta float;                   -- rad (solar declination)
    omega_s float;                 -- rad (sunset hour angle)
    D_r float;                     -- dimless (inverse relative distance)
    R_a float;                     -- MJ/m²/day (extraterrestrial radiation)
    z float;                       -- m (elevation)
    R_so float;                    -- MJ/m²/day (clear-sky radiation)
    e_a float;                     -- kPa (actual vapour pressure)
    tmin_k float;                  -- K (minimum temperature)
    tmax_k float;                  -- K (maximum temperature)
    R_s float;                     -- MJ/m²/day (solar radiation)
    R_ln float;                    -- MJ/m²/day (net longwave radiation)
BEGIN
    -- Convert latitude to radians
    phi := latitude * (PI() / 180);
    
    -- Solar declination [FAO-56 Eq.24]
    delta := 0.409 * SIN((2 * PI() / 365 * day_of_year) - 1.39);
    
    -- Sunset hour angle [FAO-56 Eq.25]
    omega_s := ACOS(-TAN(phi) * TAN(delta));    
    
    -- Inverse relative distance [FAO-56 Eq.23]
    D_r := 1 + 0.033 * COS((2 * PI() / 365) * day_of_year);    
    
    -- Extraterrestrial radiation [FAO-56 Eq.21]
    R_a := extraterrestrial_radiation(D_r, omega_s, phi, delta);
    
    -- Elevation
    z := elevation;
    
    -- Clear-sky radiation [FAO-56 Eq.37]
    R_so := clearsky_radiation(R_a, z);
    
    -- Actual vapour pressure [FAO-56 Eq.19]
    e_a := actual_vapour_pressure(tmin, tmax, rh);
    
    -- Temperature in Kelvin
    tmin_k := tmin + 273.16;
    tmax_k := tmax + 273.16;
    
    -- Solar radiation from measurement
    -- Convert W/m² to MJ/m²/day
    R_s := solar_rad * 0.0036;
   
    -- Net longwave radiation [FAO-56 Eq.39]
    R_ln := net_longwave_radiation(tmin_k, tmax_k, R_s, R_so, e_a);
    
    RETURN R_ln;
END;
$$ LANGUAGE plpgsql;

-- Net Radiation for Automatic Stations
CREATE OR REPLACE FUNCTION as_net_radiation(
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    latitude float,                -- ° (latitude in decimal degrees)
    elevation float,               -- m (station elevation)
    solar_rad float,               -- W/m² (measured solar radiation)
    rh float,                      -- % (relative humidity)
    day_of_year integer            -- 1-366 (day of year)
) RETURNS float AS $$              -- MJ/m²/day (net radiation)
DECLARE
    R_s float;                     -- MJ/m²/day (solar radiation)
    R_sn float;                    -- MJ/m²/day (net shortwave radiation)
    R_ln float;                    -- MJ/m²/day (net longwave radiation)
    R_n float;                     -- MJ/m²/day (net radiation)
BEGIN 
    -- Solar radiation from measurement
    -- Convert W/m² to MJ/m²/day
    R_s := solar_rad * 0.0036;

    -- Net shortwave radiation [FAO-56 Eq.38]
    R_sn := net_shortwave_radiation(R_s);
    
    -- Net longwave radiation for Automatic Stations [FAO-56 Eq.39]
    R_ln := as_net_longwave_radiation(tmin,tmax,latitude,elevation,solar_rad,rh, day_of_year);
    
    -- Net radiation [FAO-56 Eq.40]
    R_n := net_radiation(R_sn, R_ln);
    RETURN R_n;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equations 45 and 46)
CREATE OR REPLACE FUNCTION soil_heat_flux(
    R_s float,                     -- MJ/m²/day (solar radiation)
    R_n float                      -- MJ/m²/day (net radiation)
) RETURNS float AS $$              -- MJ/m²/day (soil heat flux)
DECLARE
    G float;                       -- MJ/m²/day (soil heat flux)
BEGIN
    IF R_s > 0 THEN
        G := 0.1 * R_n;  -- Daytime (FAO-56 Equation 45)
    ELSE
        G := 0.5 * R_n;  -- Nighttime (FAO-56 Equation 46)
    END IF;
    RETURN G;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 13)
CREATE OR REPLACE FUNCTION slope_saturation_vapour_pressure_curve(
    t float                        -- °C (mean air temperature)
) RETURNS float AS $$              -- kPa/°C (slope of vapour pressure curve)
DECLARE
    e_t float;                     -- kPa (saturation vapour pressure at t)
    delta float;                   -- kPa/°C (slope of vapour pressure curve)
BEGIN
    e_t := saturation_vapour_pressure(t);
    delta := (4098 * e_t) / POWER((t + 237.3), 2);
    RETURN delta;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION penman_monteith_evapotranspiration(
    R_n float,                     -- MJ/m²/day (net radiation)
    G float,                       -- MJ/m²/day (soil heat flux)
    T float,                       -- °C (mean daily air temperature at 2m)
    u_2 float,                     -- m/s (wind speed at 2m height)
    e_s float,                     -- kPa (saturation vapour pressure)
    e_a float,                     -- kPa (actual vapour pressure)
    delta float,                   -- kPa/°C (slope vapour pressure curve)
    gamma float                    -- kPa/°C (psychrometric constant)
) RETURNS float AS $$              -- mm/day (reference evapotranspiration)
DECLARE
    ET_0 float;                    -- mm/day (reference evapotranspiration)
BEGIN
    ET_0 := (
        (0.408 * delta * (R_n - G)) + (gamma * (900/(T + 273)) * u_2 * (e_s - e_a))
    ) / (
        delta + (gamma * (1 + 0.34 * u_2))
    );
    RETURN ET_0;
END;
$$ LANGUAGE plpgsql;


-- Penman-Monteith for Automatic Stations
CREATE OR REPLACE FUNCTION as_penman_monteith_evapotranspiration(
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    atm_press float,               -- kPa (atmospheric pressure)
    wind_spd float,                -- Knots (wind speed)
    solar_rad float,               -- W/m² (solar radiation)
    rh float,                      -- % (relative humidity)
    latitude float,                -- ° (latitude in decimal degrees)
    elevation float,               -- m (station elevation)
    day_of_year integer            -- 1-366 (day of year)
) RETURNS float AS $$              -- mm/day (reference evapotranspiration)
DECLARE
    height float;                  -- m (station height in meters)
    T float;                       -- °C (mean daily temperature)
    u_2 float;                     -- m/s (wind speed at 2m)
    e_a float;                     -- kPa (actual vapour pressure)
    e_tmin float;                  -- kPa (saturation VP at tmin)
    e_tmax float;                  -- kPa (saturation VP at tmax)
    e_s float;                     -- kPa (mean saturation VP)
    R_s float;                     -- MJ/m²/day (solar radiation)
    R_n float;                     -- MJ/m²/day (net radiation)
    G float;                       -- MJ/m²/day (soil heat flux)
    delta float;                   -- kPa/°C (slope of VP curve)
    gamma float;                   -- kPa/°C (psychrometric constant)
    ET_0 float;                    -- mm/day (reference ET)
BEGIN
    -- Mean temperature
    T := (tmin + tmax) / 2;
    
    -- Convert Knots to m/s
    u_2 := wind_spd * 0.514;

    -- param uz: wind speed at height z
    -- param z: height in meters
    -- u_2 := uz * (4.87/(log(67.8 * z - 5.42)))
    
    -- height := 10;
    -- u_2 := u_2 * (4.87/(log(67.8 * height - 5.42)));
       
    -- Actual vapour pressure [FAO-56 Eq.19]
    e_a := actual_vapour_pressure(tmin, tmax, rh);
    
    -- Saturation vapour pressures [FAO-56 Eq.11]
    e_tmin := saturation_vapour_pressure(tmin);
    e_tmax := saturation_vapour_pressure(tmax);
    
    -- Mean saturation vapour pressure [FAO-56 Eq.12]
    e_s := (e_tmin + e_tmax) / 2;
    
    -- Solar radiation
    -- Convert W/m² to MJ/m²/day
    R_s := solar_rad * 0.0036;
    
    -- Net radiation
    R_n := as_net_radiation(tmin, tmax, latitude, elevation, solar_rad, rh, day_of_year);
    
    -- Soil heat flux [FAO-56 Eqs.45-46]
    G := soil_heat_flux(R_s, R_n);
    
    -- Slope of saturation VP curve [FAO-56 Eq.13]
    delta := slope_saturation_vapour_pressure_curve(T);
    
    -- Psychrometric constant [FAO-56 Eq.8]
    gamma := 0.000665 * atm_press;
    
    -- Reference evapotranspiration [FAO-56 Eq.6]
    ET_0 := penman_monteith_evapotranspiration(R_n, G, T, u_2, e_s, e_a, delta, gamma);
    
    RETURN ET_0;
END;
$$ LANGUAGE plpgsql;


-- Hargreaves-Samani
CREATE OR REPLACE FUNCTION hargreaves_samani_evapotranspiration(
    alpha float,
    beta float,
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    R_a float,                     -- MJ/m²/day (extraterrestrial radiation)
    T float                        -- °C (mean daily air temperature at 2m)
) RETURNS float AS $$              -- 
DECLARE
    ET_0 float;
BEGIN
    ET_0 := alpha * POWER((tmax - tmin), beta) * (T + 17.8) * R_a * 0.408;
    RETURN ET_0;
END;
$$ LANGUAGE plpgsql;


-- Hargreaves-Samani for Automatic Stations
CREATE OR REPLACE FUNCTION as_hargreaves_samani_evapotranspiration(
    alpha float,
    beta float,
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    latitude float,                -- ° (latitude in decimal degrees)
    day_of_year integer            -- 1-366 (day of year)
) RETURNS float AS $$              --
DECLARE
    D_r float;                     -- Dimensionless (inverse relative Earth-Sun distance) [FAO-56 Eq.23]
    omega_s float;                 -- Radians (sunset hour angle) [FAO-56 Eq.25]
    phi float;                     -- Radians (latitude) 
    delta float;                   -- Radians (solar declination) [FAO-56 Eq.24]
    R_a float;                     -- MJ/m²/day (extraterrestrial radiation)
    T float;                       -- °C (mean daily air temperature at 2m)
    ET_0 float;
BEGIN
    -- Convert latitude to radians
    phi := latitude * (PI() / 180);
    
    -- Solar declination [FAO-56 Eq.24]
    delta := 0.409 * SIN((2 * PI() / 365 * day_of_year) - 1.39);
    
    -- Sunset hour angle [FAO-56 Eq.25]
    omega_s := ACOS(-TAN(phi) * TAN(delta));    
    
    -- Inverse relative distance [FAO-56 Eq.23]
    D_r := 1 + 0.033 * COS((2 * PI() / 365) * day_of_year);    
    
    -- Extraterrestrial radiation [FAO-56 Eq.21]
    R_a := extraterrestrial_radiation(D_r, omega_s, phi, delta);

    -- Mean daily air temperature at 2m
    T := (tmin + tmax) / 2;

    ET_0 := hargreaves_samani_evapotranspiration(alpha, beta, tmin, tmax, T, R_a);
    RETURN ET_0;
END;
$$ LANGUAGE plpgsql;

-- Daily Data from Hourly Summary
WITH hourly_data AS (
    SELECT
        station_id 
        ,vr.symbol AS variable
        ,DATE(datetime AT TIME ZONE '{{timezone}}') AS day
        ,EXTRACT(HOUR FROM datetime AT TIME ZONE '{{timezone}}') AS hour
        ,min_value
        ,max_value
        ,avg_value
        ,sum_value
    FROM hourly_summary hs
    JOIN wx_variable vr ON vr.id = hs.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol IN ('TEMP','SOLARRAD', 'RH', 'PRESSTN', 'WNDSPD')
      AND datetime AT TIME ZONE '{{timezone}}' >= '{{ start_date }}'
      AND datetime AT TIME ZONE '{{timezone}}' < '{{ end_date }}'
)
,daily_data AS (
    SELECT
        station_id
        ,day
        ,day_of_month
        ,day_of_year
        ,month
        ,year
        ,st.latitude::float AS latitude
        ,st.elevation::float AS elevation
        ,{{alpha}} AS alpha
        ,{{beta}} AS beta
        ,tmin
        ,tmax
        ,rh
        ,wind_spd
        ,atm_press
        ,solar_rad
    FROM (
        SELECT
            station_id
            ,day
            ,EXTRACT(DAY FROM day) AS day_of_month
            ,EXTRACT(DOY FROM day)::integer AS day_of_year
            ,EXTRACT(MONTH FROM day) AS month
            ,EXTRACT(YEAR FROM day) AS year
            ,COUNT(DISTINCT hour) AS total_hours
            ,MIN(tmin) AS tmin
            ,MAX(tmax) AS tmax
            ,AVG(rh) AS rh
            ,AVG(wind_spd) AS wind_spd
            ,AVG(atm_press) AS atm_press
            ,SUM(solar_rad) AS solar_rad
        FROM (
            SELECT
                station_id
                ,day
                ,hour
                ,MIN(CASE variable WHEN 'TEMP' THEN min_value ELSE NULL END)::float AS tmin
                ,MIN(CASE variable WHEN 'TEMP' THEN max_value ELSE NULL END)::float AS tmax
                ,MIN(CASE variable WHEN 'RH' THEN avg_value ELSE NULL END)::float AS rh
                ,MIN(CASE variable WHEN 'WNDSPD' THEN avg_value ELSE NULL END)::float AS wind_spd
                ,MIN(CASE variable WHEN 'PRESSTN' THEN avg_value ELSE NULL END)::float AS atm_press
                ,MIN(CASE variable WHEN 'SOLARRAD' THEN sum_value ELSE NULL END)::float AS solar_rad
            FROM hourly_data
            GROUP BY station_id, day, hour
        ) hav -- Hourly Aggregated variables
        WHERE tmin IS NOT NULL
          AND tmax IS NOT NULL
          AND rh IS NOT NULL
          AND wind_spd IS NOT NULL
          AND atm_press IS NOT NULL
          AND solar_rad IS NOT NULL
        GROUP BY station_id, day    
    ) ddr -- Daily Data Raw
    JOIN wx_station st ON st.id = ddr.station_id
    WHERE 100*(total_hours::numeric/24) > (100-{{max_hour_pct}})
)
-- ,daily_data AS (
--     SELECT
--         station_id
--         ,day
--         ,day_of_month
--         ,day_of_year
--         ,month
--         ,year
--         ,st.latitude::float AS latitude
--         ,st.elevation::float AS elevation
--         ,{{alpha}} AS alpha
--         ,{{beta}} AS beta
--         ,tmin
--         ,tmax
--         ,rh
--         ,wind_spd
--         ,atm_press
--         ,solar_rad        
--     FROM (
--         SELECT
--             station_id
--             ,day
--             ,EXTRACT(DAY FROM day) AS day_of_month
--             ,EXTRACT(DOY FROM day)::integer AS day_of_year
--             ,EXTRACT(MONTH FROM day) AS month
--             ,EXTRACT(YEAR FROM day) AS year      
--             ,COUNT(DISTINCT hour) AS total_hours
--             ,MIN(CASE WHEN variable = 'TEMP' THEN min_value ELSE NULL END)::float AS tmin
--             ,MAX(CASE WHEN variable = 'TEMP' THEN max_value ELSE NULL END)::float AS tmax
--             ,AVG(CASE WHEN variable = 'RH' THEN avg_value ELSE NULL END)::float AS rh
--             ,AVG(CASE WHEN variable = 'WNDSPD' THEN avg_value ELSE NULL END)::float AS wind_spd
--             ,AVG(CASE WHEN variable = 'PRESSTN' THEN avg_value ELSE NULL END)::float AS atm_press
--             ,SUM(CASE WHEN variable = 'SOLARRAD' THEN sum_value ELSE NULL END)::float AS solar_rad
--         FROM hourly_data
--         GROUP BY station_id, day    
--     ) ddr
--     JOIN wx_station st ON st.id = ddr.station_id
--     WHERE 100*(total_hours::numeric/24) > (100-{{max_hour_pct}})
-- )
-- Daily Data from Daily Summary
-- WITH daily_data AS (
--     SELECT
--         station_id
--         ,day
--         ,EXTRACT(DAY FROM day) AS day_of_month
--         ,EXTRACT(DOY FROM day)::integer AS day_of_year
--         ,EXTRACT(MONTH FROM day) AS month
--         ,EXTRACT(YEAR FROM day) AS year
--         ,st.latitude::float AS latitude
--         ,st.elevation::float AS elevation
--         ,{{alpha}} AS alpha
--         ,{{beta}} AS beta        
--         ,MIN(CASE WHEN vr.symbol = 'TEMP' THEN min_value ELSE NULL END)::float AS tmin
--         ,MAX(CASE WHEN vr.symbol = 'TEMP' THEN max_value ELSE NULL END)::float AS tmax
--         ,AVG(CASE WHEN vr.symbol = 'RH' THEN avg_value ELSE NULL END)::float AS rh
--         ,AVG(CASE WHEN vr.symbol = 'WNDSPD' THEN avg_value ELSE NULL END)::float AS wind_spd
--         ,AVG(CASE WHEN vr.symbol = 'PRESSTN' THEN avg_value ELSE NULL END)::float AS atm_press
--         ,SUM(CASE WHEN vr.symbol = 'SOLARRAD' THEN sum_value ELSE NULL END)::float AS solar_rad
--     FROM daily_summary ds
--     JOIN wx_variable vr ON vr.id = ds.variable_id
--     JOIN wx_station st ON st.id = ds.station_id
--     WHERE station_id = {{station_id}}
--       AND vr.symbol IN ('TEMP','SOLARRAD', 'RH', 'PRESSTN', 'WNDSPD')
--       AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
--     GROUP BY station_id, day, latitude, elevation
-- )
,evapotranspiration_calc AS(
    SELECT
        station_id
        ,day_of_month
        ,month
        ,year
        ,as_hargreaves_samani_evapotranspiration(alpha, beta, tmin, tmax, latitude, day_of_year) AS hargreaves_samani
        ,as_penman_monteith_evapotranspiration(tmin, tmax, atm_press, wind_spd, solar_rad, rh, latitude, elevation, day_of_year) AS penman_monteith
        ,elevation
        ,atm_press
        ,wind_spd 
        ,solar_rad
        ,rh
    FROM daily_data
)
,extended_data AS(
    SELECT
        station_id
        ,day_of_month
        ,CASE 
            WHEN month=12 THEN 0
            WHEN month=1 THEN 13
        END as month
        ,CASE 
            WHEN month=12 THEN year+1
            WHEN month=1 THEN year-1
        END as year
        ,hargreaves_samani
        ,penman_monteith
        ,elevation
        ,atm_press
        ,wind_spd
        ,solar_rad
        ,rh        
    FROM evapotranspiration_calc
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM evapotranspiration_calc
)
SELECT
    st.name AS station
    ,products.product AS product
    ,year
    ,month
    ,day_of_month
    ,ROUND(st.elevation::numeric, 2) AS elevation
    ,ROUND(atm_press::numeric, 2) AS atm_press
    ,ROUND(wind_spd::numeric, 2) AS wind_spd
    ,ROUND(solar_rad::numeric, 2) AS solar_rad
    ,ROUND(rh::numeric, 2) AS rh
    ,CASE product
        WHEN 'HARGREAVES-SAMANI' THEN ROUND(hargreaves_samani::numeric, 2)
        WHEN 'PENMAN-MONTEITH' THEN ROUND(penman_monteith::numeric, 2)
    END AS evapotranspiration
FROM extended_data ed
JOIN wx_station st ON st.id=ed.station_id
CROSS JOIN (VALUES ('HARGREAVES-SAMANI'), ('PENMAN-MONTEITH')) AS products(product)
WHERE year BETWEEN {{start_year}} AND {{end_year}}  
    AND month in ({{aggregation_months}})
