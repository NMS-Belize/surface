-- https://www.fao.org/4/x0490e/x0490e07.htm#chapter%203%20%20%20meteorological%20data

DROP FUNCTION IF EXISTS clearsky_radiation(double precision,double precision);

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


-- Allen et al. (1998), FAO-56 (Equation 38).
CREATE OR REPLACE FUNCTION as_net_shortwave_radiation(
    solar_rad float,               -- W/m²y (solar radiation)
    albedo float DEFAULT 0.23      -- dimensionless (surface albedo)
) RETURNS float AS $$              -- MJ/m²/day (net shortwave radiation)
DECLARE
    R_s float;                     -- MJ/m²y (solar radiation)
    R_sn float;                    -- MJ/m²/day (net shortwave radiation)
BEGIN
    -- Solar radiation
    -- Convert W/m² to MJ/m²/day
    R_s := solar_rad * 0.0036;

    R_sn := (1 - albedo) * R_s;
    RETURN R_sn;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION as_net_longwave_radiation(
    tmax float,                    -- °C (daily maximum temperature)
    tmin float,                    -- °C (daily minimum temperature)
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
    
    -- Solar radiation
    -- Convert W/m² to MJ/m²/day
    R_s := solar_rad * 0.0036;
   
    -- Net longwave radiation [FAO-56 Eq.39]
    R_ln := net_longwave_radiation(tmin_k, tmax_k, R_s, R_so, e_a);
    
    RETURN R_ln;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION as_net_radiation(
    tmax float,                    -- °C (daily maximum temperature)
    tmin float,                    -- °C (daily minimum temperature)
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
    -- R_s := solar_rad * 0.0036;

    -- Net shortwave radiation [FAO-56 Eq.38]
    R_sn := as_net_shortwave_radiation(solar_rad);
    
    -- Net longwave radiation for Automatic Stations [FAO-56 Eq.39]
    R_ln := as_net_longwave_radiation(tmax,tmin,latitude,elevation,solar_rad,rh, day_of_year);
    
    -- Net radiation [FAO-56 Eq.40]
    R_n := net_radiation(R_sn, R_ln);
    RETURN R_n;
END;
$$ LANGUAGE plpgsql;


WITH month_days AS (
    SELECT
        EXTRACT(MONTH FROM day) AS month,
        EXTRACT(YEAR FROM day) AS year,        
        EXTRACT(DAY FROM (DATE_TRUNC('MONTH', day) + INTERVAL '1 MONTH' - INTERVAL '1 day')) AS days_in_month
    FROM
    (SELECT generate_series('{{ start_date }}'::date, '{{ end_date }}'::date, '1 MONTH'::interval)::date AS day) AS days
)
,extended_month_days AS (
    SELECT
        CASE 
            WHEN month=12 THEN 0
            WHEN month=1 THEN 13
        END as month
        ,CASE 
            WHEN month=12 THEN year+1
            WHEN month=1 THEN year-1
        END as year
        ,days_in_month
    FROM month_days
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM month_days
)
,aggreation_total_days AS(
    SELECT
        year
        ,SUM(CASE WHEN month IN (1, 2, 3) THEN days_in_month ELSE 0 END) AS "JFM_total"
        ,SUM(CASE WHEN month IN (2, 3, 4) THEN days_in_month ELSE 0 END) AS "FMA_total"
        ,SUM(CASE WHEN month IN (3, 4, 5) THEN days_in_month ELSE 0 END) AS "MAM_total"
        ,SUM(CASE WHEN month IN (4, 5, 6) THEN days_in_month ELSE 0 END) AS "AMJ_total"
        ,SUM(CASE WHEN month IN (5, 6, 7) THEN days_in_month ELSE 0 END) AS "MJJ_total"
        ,SUM(CASE WHEN month IN (6, 7, 8) THEN days_in_month ELSE 0 END) AS "JJA_total"
        ,SUM(CASE WHEN month IN (7, 8, 9) THEN days_in_month ELSE 0 END) AS "JAS_total"
        ,SUM(CASE WHEN month IN (8, 9, 10) THEN days_in_month ELSE 0 END) AS "ASO_total"
        ,SUM(CASE WHEN month IN (9, 10, 11) THEN days_in_month ELSE 0 END) AS "SON_total"
        ,SUM(CASE WHEN month IN (10, 11, 12) THEN days_in_month ELSE 0 END) AS "OND_total"
        ,SUM(CASE WHEN month IN (11, 12, 13) THEN days_in_month ELSE 0 END) AS "NDJ_total"
        ,SUM(CASE WHEN month IN (0, 1, 2, 3, 4, 5) THEN days_in_month ELSE 0 END) AS "DRY_total"
        ,SUM(CASE WHEN month IN (6, 7, 8, 9, 10, 11) THEN days_in_month ELSE 0 END) AS "WET_total"
        ,SUM(CASE WHEN month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) THEN days_in_month ELSE 0 END) AS "ANNUAL_total"
        ,SUM(CASE WHEN month IN (0, 1, 2, 3) THEN days_in_month ELSE 0 END) AS "DJFM_total"
    FROM extended_month_days
    GROUP BY year
)
,hourly_data AS (
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
      AND vr.symbol IN ('TEMP', 'RH', 'SOLARRAD')
      AND datetime AT TIME ZONE '{{timezone}}' >= '{{ start_date }}'
      AND datetime AT TIME ZONE '{{timezone}}' < '{{ end_date }}'
)
,daily_data AS (
    SELECT 
        st.id AS station_id
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,EXTRACT(DOY FROM day)::integer AS day_of_year
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,st.latitude AS latitude
        ,st.elevation AS elevation        
        ,MIN(CASE WHEN variable = 'TEMP' THEN tmin END) AS tmin
        ,MAX(CASE WHEN variable = 'TEMP' THEN tmax END) AS tmax
        ,AVG(CASE WHEN variable = 'RH' THEN rh END) AS rh
        ,SUM(CASE WHEN variable = 'SOLARRAD' THEN solar_rad END) AS solar_rad        
    FROM (
        SELECT
            station_id
            ,variable
            ,day
            ,COUNT(DISTINCT day) AS total_hours
            ,MIN(CASE WHEN variable = 'TEMP' THEN min_value END) AS tmin
            ,MAX(CASE WHEN variable = 'TEMP' THEN max_value END) AS tmax
            ,AVG(CASE WHEN variable = 'RH' THEN avg_value END) AS rh
            ,SUM(CASE WHEN variable = 'SOLARRAD' THEN sum_value END) AS solar_rad
        FROM hourly_data
        GROUP BY station_id, day, variable
    ) ddr
    JOIN wx_station st ON st.id = ddr.station_id
    WHERE 100*(total_hours::numeric/24) > (100-{{max_hour_pct}})
    GROUP BY st.id, day
)
-- ,daily_data AS (
--     SELECT
--         station_id
--         ,day
--         ,EXTRACT(DAY FROM day) AS day_of_month
--         ,EXTRACT(DOY FROM day)::integer AS day_of_year
--         ,EXTRACT(MONTH FROM day) AS month
--         ,EXTRACT(YEAR FROM day) AS year
--         ,st.latitude::float AS latitude
--         ,st.elevation::float AS elevation
--         ,MAX(CASE WHEN vr.symbol = 'TEMP' THEN max_value ELSE NULL END)::float AS tmax
--         ,MIN(CASE WHEN vr.symbol = 'TEMP' THEN min_value ELSE NULL END)::float AS tmin
--         ,AVG(CASE WHEN vr.symbol = 'RH' THEN avg_value ELSE NULL END)::float AS rh
--         ,SUM(CASE WHEN vr.symbol = 'SOLARRAD' THEN sum_value ELSE NULL END)::float AS solar_rad
--     FROM daily_summary ds
--     JOIN wx_variable vr ON vr.id = ds.variable_id
--     JOIN wx_station st ON st.id = ds.station_id
--     WHERE station_id = {{station_id}}
--       AND vr.symbol IN ('TEMP','SOLARRAD', 'RH')
--       AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
--     GROUP BY station_id, day, latitude, elevation
-- )
,net_rad_calc AS (
    SELECT 
        station_id
        ,day
        ,day_of_month
        ,month
        ,year
        -- Convert W/m² to MJ/m²/day
        ,solar_rad * 0.0036 AS solar_rad
        ,as_net_shortwave_radiation(solar_rad) AS net_shortwave_rad
        ,as_net_longwave_radiation(tmax, tmin, latitude, elevation, solar_rad, rh, day_of_year) AS net_longwave_rad
        ,as_net_radiation(tmax, tmin, latitude, elevation, solar_rad, rh, day_of_year) AS net_rad
    FROM daily_data
    WHERE tmin IS NOT NULL
      AND tmax IS NOT NULL
      AND latitude IS NOT NULL
      AND elevation IS NOT NULL
      AND solar_rad IS NOT NULL
      AND rh IS NOT NULL
)
,extended_data AS(
    SELECT
        station_id
        ,day
        ,day_of_month
        ,CASE 
            WHEN month=12 THEN 0
            WHEN month=1 THEN 13
        END as month
        ,CASE 
            WHEN month=12 THEN year+1
            WHEN month=1 THEN year-1
        END as year
        ,solar_rad
        ,net_shortwave_rad
        ,net_longwave_rad
        ,net_rad
    FROM net_rad_calc
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM net_rad_calc
)
,daily_lagged_data AS (
    SELECT
        *
        ,CASE WHEN month IN (1, 2, 3) THEN TRUE ELSE FALSE END AS is_jfm
        ,CASE WHEN month IN (2, 3, 4) THEN TRUE ELSE FALSE END AS is_fma
        ,CASE WHEN month IN (3, 4, 5) THEN TRUE ELSE FALSE END AS is_mam
        ,CASE WHEN month IN (4, 5, 6) THEN TRUE ELSE FALSE END AS is_amj
        ,CASE WHEN month IN (5, 6, 7) THEN TRUE ELSE FALSE END AS is_mjj
        ,CASE WHEN month IN (6, 7, 8) THEN TRUE ELSE FALSE END AS is_jja
        ,CASE WHEN month IN (7, 8, 9) THEN TRUE ELSE FALSE END AS is_jas
        ,CASE WHEN month IN (8, 9, 10) THEN TRUE ELSE FALSE END AS is_aso
        ,CASE WHEN month IN (9, 10, 11) THEN TRUE ELSE FALSE END AS is_son
        ,CASE WHEN month IN (10, 11, 12) THEN TRUE ELSE FALSE END AS is_ond
        ,CASE WHEN month IN (11, 12, 13) THEN TRUE ELSE FALSE END AS is_ndj
        ,CASE WHEN month IN (0, 1, 2, 3, 4, 5) THEN TRUE ELSE FALSE END AS is_dry
        ,CASE WHEN month IN (6, 7, 8, 9, 10, 11) THEN TRUE ELSE FALSE END AS is_wet
        ,CASE WHEN month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) THEN TRUE ELSE FALSE END AS is_annual
        ,CASE WHEN month IN (0, 1, 2, 3) THEN TRUE ELSE FALSE END AS is_djfm        
        ,day - 1 - LAG(day) OVER (PARTITION BY station_id, year ORDER BY day) AS day_gap       
        
    FROM extended_data
    WHERE year BETWEEN {{start_year}} AND {{end_year}}
)
,aggreated_data AS (
    SELECT
        st.name AS station
        ,year
        ,ROUND(SUM(CASE WHEN is_jfm THEN solar_rad END)::numeric, 2) AS "JFM_solar"
        ,ROUND(SUM(CASE WHEN is_jfm THEN net_shortwave_rad END)::numeric, 2) AS "JFM_net_sw"
        ,ROUND(SUM(CASE WHEN is_jfm THEN net_longwave_rad END)::numeric, 2) AS "JFM_net_lw"
        ,ROUND(SUM(CASE WHEN is_jfm THEN net_rad END)::numeric, 2) AS "JFM_net"
        ,COUNT(DISTINCT CASE WHEN ((is_jfm) AND (day IS NOT NULL)) THEN day END) AS "JFM_count"
        ,MAX(CASE WHEN ((is_jfm) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JFM_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_fma THEN solar_rad END)::numeric, 2) AS "FMA_solar"
        ,ROUND(SUM(CASE WHEN is_fma THEN net_shortwave_rad END)::numeric, 2) AS "FMA_net_sw"
        ,ROUND(SUM(CASE WHEN is_fma THEN net_longwave_rad END)::numeric, 2) AS "FMA_net_lw"
        ,ROUND(SUM(CASE WHEN is_fma THEN net_rad END)::numeric, 2) AS "FMA_net"
        ,COUNT(DISTINCT CASE WHEN ((is_fma) AND (day IS NOT NULL)) THEN day END) AS "FMA_count"
        ,MAX(CASE WHEN ((is_fma) AND NOT (month = 2 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "FMA_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_mam THEN solar_rad END)::numeric, 2) AS "MAM_solar"
        ,ROUND(SUM(CASE WHEN is_mam THEN net_shortwave_rad END)::numeric, 2) AS "MAM_net_sw"
        ,ROUND(SUM(CASE WHEN is_mam THEN net_longwave_rad END)::numeric, 2) AS "MAM_net_lw"
        ,ROUND(SUM(CASE WHEN is_mam THEN net_rad END)::numeric, 2) AS "MAM_net"
        ,COUNT(DISTINCT CASE WHEN ((is_mam) AND (day IS NOT NULL)) THEN day END) AS "MAM_count"
        ,MAX(CASE WHEN ((is_mam) AND NOT (month = 3 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MAM_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_amj THEN solar_rad END)::numeric, 2) AS "AMJ_solar"
        ,ROUND(SUM(CASE WHEN is_amj THEN net_shortwave_rad END)::numeric, 2) AS "AMJ_net_sw"
        ,ROUND(SUM(CASE WHEN is_amj THEN net_longwave_rad END)::numeric, 2) AS "AMJ_net_lw"
        ,ROUND(SUM(CASE WHEN is_amj THEN net_rad END)::numeric, 2) AS "AMJ_net"
        ,COUNT(DISTINCT CASE WHEN ((is_amj) AND (day IS NOT NULL)) THEN day END) AS "AMJ_count"
        ,MAX(CASE WHEN ((is_amj) AND NOT (month = 4 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "AMJ_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_mjj THEN solar_rad END)::numeric, 2) AS "MJJ_solar"
        ,ROUND(SUM(CASE WHEN is_mjj THEN net_shortwave_rad END)::numeric, 2) AS "MJJ_net_sw"
        ,ROUND(SUM(CASE WHEN is_mjj THEN net_longwave_rad END)::numeric, 2) AS "MJJ_net_lw"
        ,ROUND(SUM(CASE WHEN is_mjj THEN net_rad END)::numeric, 2) AS "MJJ_net"
        ,COUNT(DISTINCT CASE WHEN ((is_mjj) AND (day IS NOT NULL)) THEN day END) AS "MJJ_count"
        ,MAX(CASE WHEN ((is_mjj) AND NOT (month = 5 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MJJ_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_jja THEN solar_rad END)::numeric, 2) AS "JJA_solar"
        ,ROUND(SUM(CASE WHEN is_jja THEN net_shortwave_rad END)::numeric, 2) AS "JJA_net_sw"
        ,ROUND(SUM(CASE WHEN is_jja THEN net_longwave_rad END)::numeric, 2) AS "JJA_net_lw"
        ,ROUND(SUM(CASE WHEN is_jja THEN net_rad END)::numeric, 2) AS "JJA_net"
        ,COUNT(DISTINCT CASE WHEN ((is_jja) AND (day IS NOT NULL)) THEN day END) AS "JJA_count"
        ,MAX(CASE WHEN ((is_jja) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JJA_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_jas THEN solar_rad END)::numeric, 2) AS "JAS_solar"
        ,ROUND(SUM(CASE WHEN is_jas THEN net_shortwave_rad END)::numeric, 2) AS "JAS_net_sw"
        ,ROUND(SUM(CASE WHEN is_jas THEN net_longwave_rad END)::numeric, 2) AS "JAS_net_lw"
        ,ROUND(SUM(CASE WHEN is_jas THEN net_rad END)::numeric, 2) AS "JAS_net"
        ,COUNT(DISTINCT CASE WHEN ((is_jas) AND (day IS NOT NULL)) THEN day END) AS "JAS_count"
        ,MAX(CASE WHEN ((is_jas) AND NOT (month = 7 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JAS_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_aso THEN solar_rad END)::numeric, 2) AS "ASO_solar"
        ,ROUND(SUM(CASE WHEN is_aso THEN net_shortwave_rad END)::numeric, 2) AS "ASO_net_sw"
        ,ROUND(SUM(CASE WHEN is_aso THEN net_longwave_rad END)::numeric, 2) AS "ASO_net_lw"
        ,ROUND(SUM(CASE WHEN is_aso THEN net_rad END)::numeric, 2) AS "ASO_net"
        ,COUNT(DISTINCT CASE WHEN ((is_aso) AND (day IS NOT NULL)) THEN day END) AS "ASO_count"
        ,MAX(CASE WHEN ((is_aso) AND NOT (month = 8 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ASO_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_son THEN solar_rad END)::numeric, 2) AS "SON_solar"
        ,ROUND(SUM(CASE WHEN is_son THEN net_shortwave_rad END)::numeric, 2) AS "SON_net_sw"
        ,ROUND(SUM(CASE WHEN is_son THEN net_longwave_rad END)::numeric, 2) AS "SON_net_lw"
        ,ROUND(SUM(CASE WHEN is_son THEN net_rad END)::numeric, 2) AS "SON_net"
        ,COUNT(DISTINCT CASE WHEN ((is_son) AND (day IS NOT NULL)) THEN day END) AS "SON_count"
        ,MAX(CASE WHEN ((is_son) AND NOT (month = 9 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "SON_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_ond THEN solar_rad END)::numeric, 2) AS "OND_solar"
        ,ROUND(SUM(CASE WHEN is_ond THEN net_shortwave_rad END)::numeric, 2) AS "OND_net_sw"
        ,ROUND(SUM(CASE WHEN is_ond THEN net_longwave_rad END)::numeric, 2) AS "OND_net_lw"
        ,ROUND(SUM(CASE WHEN is_ond THEN net_rad END)::numeric, 2) AS "OND_net"
        ,COUNT(DISTINCT CASE WHEN ((is_ond) AND (day IS NOT NULL)) THEN day END) AS "OND_count"
        ,MAX(CASE WHEN ((is_ond) AND NOT (month = 10 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "OND_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_ndj THEN solar_rad END)::numeric, 2) AS "NDJ_solar"
        ,ROUND(SUM(CASE WHEN is_ndj THEN net_shortwave_rad END)::numeric, 2) AS "NDJ_net_sw"
        ,ROUND(SUM(CASE WHEN is_ndj THEN net_longwave_rad END)::numeric, 2) AS "NDJ_net_lw"
        ,ROUND(SUM(CASE WHEN is_ndj THEN net_rad END)::numeric, 2) AS "NDJ_net"
        ,COUNT(DISTINCT CASE WHEN ((is_ndj) AND (day IS NOT NULL)) THEN day END) AS "NDJ_count"
        ,MAX(CASE WHEN ((is_ndj) AND NOT (month = 11 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "NDJ_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_dry THEN solar_rad END)::numeric, 2) AS "DRY_solar"
        ,ROUND(SUM(CASE WHEN is_dry THEN net_shortwave_rad END)::numeric, 2) AS "DRY_net_sw"
        ,ROUND(SUM(CASE WHEN is_dry THEN net_longwave_rad END)::numeric, 2) AS "DRY_net_lw"
        ,ROUND(SUM(CASE WHEN is_dry THEN net_rad END)::numeric, 2) AS "DRY_net"
        ,COUNT(DISTINCT CASE WHEN ((is_dry) AND (day IS NOT NULL)) THEN day END) AS "DRY_count"
        ,MAX(CASE WHEN ((is_dry) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "DRY_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_wet THEN solar_rad END)::numeric, 2) AS "WET_solar"
        ,ROUND(SUM(CASE WHEN is_wet THEN net_shortwave_rad END)::numeric, 2) AS "WET_net_sw"
        ,ROUND(SUM(CASE WHEN is_wet THEN net_longwave_rad END)::numeric, 2) AS "WET_net_lw"
        ,ROUND(SUM(CASE WHEN is_wet THEN net_rad END)::numeric, 2) AS "WET_net"
        ,COUNT(DISTINCT CASE WHEN ((is_wet) AND (day IS NOT NULL)) THEN day END) AS "WET_count"
        ,MAX(CASE WHEN ((is_wet) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "WET_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_annual THEN solar_rad END)::numeric, 2) AS "ANNUAL_solar"
        ,ROUND(SUM(CASE WHEN is_annual THEN net_shortwave_rad END)::numeric, 2) AS "ANNUAL_net_sw"
        ,ROUND(SUM(CASE WHEN is_annual THEN net_longwave_rad END)::numeric, 2) AS "ANNUAL_net_lw"
        ,ROUND(SUM(CASE WHEN is_annual THEN net_rad END)::numeric, 2) AS "ANNUAL_net"
        ,COUNT(DISTINCT CASE WHEN ((is_annual) AND (day IS NOT NULL)) THEN day END) AS "ANNUAL_count"
        ,MAX(CASE WHEN ((is_annual) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ANNUAL_max_day_gap"
        ,ROUND(SUM(CASE WHEN is_djfm THEN solar_rad END)::numeric, 2) AS "DJFM_solar"
        ,ROUND(SUM(CASE WHEN is_djfm THEN net_shortwave_rad END)::numeric, 2) AS "DJFM_net_sw"
        ,ROUND(SUM(CASE WHEN is_djfm THEN net_longwave_rad END)::numeric, 2) AS "DJFM_net_lw"
        ,ROUND(SUM(CASE WHEN is_djfm THEN net_rad END)::numeric, 2) AS "DJFM_net"
        ,COUNT(DISTINCT CASE WHEN ((is_djfm) AND (day IS NOT NULL)) THEN day END) AS "DJFM_count"
        ,MAX(CASE WHEN ((is_djfm) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "DJFM_max_day_gap"
    FROM daily_lagged_data dld
    JOIN wx_station st ON st.id = dld.station_id
    GROUP BY st.name, year
)
,aggregation_pct AS (
    SELECT
        station
        ,ad.year
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_solar" ELSE NULL END AS "JFM_solar"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_net_sw" ELSE NULL END AS "JFM_net_sw"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_net_lw" ELSE NULL END AS "JFM_net_lw"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_net" ELSE NULL END AS "JFM_net"
        ,ROUND(((100*(CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_count" ELSE 0 END))::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_solar" ELSE NULL END AS "FMA_solar"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_net_sw" ELSE NULL END AS "FMA_net_sw"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_net_lw" ELSE NULL END AS "FMA_net_lw"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_net" ELSE NULL END AS "FMA_net"
        ,ROUND(((100*(CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_count" ELSE 0 END))::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_solar" ELSE NULL END AS "MAM_solar"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_net_sw" ELSE NULL END AS "MAM_net_sw"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_net_lw" ELSE NULL END AS "MAM_net_lw"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_net" ELSE NULL END AS "MAM_net"
        ,ROUND(((100*(CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_count" ELSE 0 END))::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_solar" ELSE NULL END AS "AMJ_solar"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_net_sw" ELSE NULL END AS "AMJ_net_sw"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_net_lw" ELSE NULL END AS "AMJ_net_lw"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_net" ELSE NULL END AS "AMJ_net"
        ,ROUND(((100*(CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_count" ELSE 0 END))::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_solar" ELSE NULL END AS "MJJ_solar"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_net_sw" ELSE NULL END AS "MJJ_net_sw"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_net_lw" ELSE NULL END AS "MJJ_net_lw"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_net" ELSE NULL END AS "MJJ_net"
        ,ROUND(((100*(CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_count" ELSE 0 END))::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_solar" ELSE NULL END AS "JJA_solar"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_net_sw" ELSE NULL END AS "JJA_net_sw"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_net_lw" ELSE NULL END AS "JJA_net_lw"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_net" ELSE NULL END AS "JJA_net"
        ,ROUND(((100*(CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_count" ELSE 0 END))::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_solar" ELSE NULL END AS "JAS_solar"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_net_sw" ELSE NULL END AS "JAS_net_sw"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_net_lw" ELSE NULL END AS "JAS_net_lw"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_net" ELSE NULL END AS "JAS_net"
        ,ROUND(((100*(CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_count" ELSE 0 END))::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_solar" ELSE NULL END AS "ASO_solar"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_net_sw" ELSE NULL END AS "ASO_net_sw"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_net_lw" ELSE NULL END AS "ASO_net_lw"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_net" ELSE NULL END AS "ASO_net"
        ,ROUND(((100*(CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_count" ELSE 0 END))::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_solar" ELSE NULL END AS "SON_solar"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_net_sw" ELSE NULL END AS "SON_net_sw"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_net_lw" ELSE NULL END AS "SON_net_lw"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_net" ELSE NULL END AS "SON_net"
        ,ROUND(((100*(CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_count" ELSE 0 END))::numeric/"SON_total"::numeric),2) AS "SON (% of days)"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_solar" ELSE NULL END AS "OND_solar"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_net_sw" ELSE NULL END AS "OND_net_sw"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_net_lw" ELSE NULL END AS "OND_net_lw"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_net" ELSE NULL END AS "OND_net"
        ,ROUND(((100*(CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_count" ELSE 0 END))::numeric/"OND_total"::numeric),2) AS "OND (% of days)"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_solar" ELSE NULL END AS "NDJ_solar"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_net_sw" ELSE NULL END AS "NDJ_net_sw"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_net_lw" ELSE NULL END AS "NDJ_net_lw"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_net" ELSE NULL END AS "NDJ_net"
        ,ROUND(((100*(CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_count" ELSE 0 END))::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_solar" ELSE NULL END AS "DRY_solar"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_net_sw" ELSE NULL END AS "DRY_net_sw"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_net_lw" ELSE NULL END AS "DRY_net_lw"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_net" ELSE NULL END AS "DRY_net"
        ,ROUND(((100*(CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_count" ELSE 0 END))::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_solar" ELSE NULL END AS "WET_solar"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_net_sw" ELSE NULL END AS "WET_net_sw"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_net_lw" ELSE NULL END AS "WET_net_lw"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_net" ELSE NULL END AS "WET_net"
        ,ROUND(((100*(CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_count" ELSE 0 END))::numeric/"WET_total"::numeric),2) AS "WET (% of days)"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_solar" ELSE NULL END AS "ANNUAL_solar"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_net_sw" ELSE NULL END AS "ANNUAL_net_sw"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_net_lw" ELSE NULL END AS "ANNUAL_net_lw"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_net" ELSE NULL END AS "ANNUAL_net"
        ,ROUND(((100*(CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_count" ELSE 0 END))::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_solar" ELSE NULL END AS "DJFM_solar"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_net_sw" ELSE NULL END AS "DJFM_net_sw"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_net_lw" ELSE NULL END AS "DJFM_net_lw"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_net" ELSE NULL END AS "DJFM_net"
        ,ROUND(((100*(CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_count" ELSE 0 END))::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"
    FROM aggreated_data ad
    LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
)
SELECT
    station
    ,product
    ,year
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "JFM_solar"
            WHEN 'Net Shortwave Radiation' THEN "JFM_net_sw"
            WHEN 'Net Longwave Radiation' THEN "JFM_net_lw"
            WHEN 'Net Radiation' THEN "JFM_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "JFM_1"
    ,"JFM (% of days)" 
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "FMA_solar"
            WHEN 'Net Shortwave Radiation' THEN "FMA_net_sw"
            WHEN 'Net Longwave Radiation' THEN "FMA_net_lw"
            WHEN 'Net Radiation' THEN "FMA_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "FMA_1"
    ,"FMA (% of days)"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "MAM_solar"
            WHEN 'Net Shortwave Radiation' THEN "MAM_net_sw"
            WHEN 'Net Longwave Radiation' THEN "MAM_net_lw"
            WHEN 'Net Radiation' THEN "MAM_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "MAM_1"
    ,"MAM (% of days)"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "AMJ_solar"
            WHEN 'Net Shortwave Radiation' THEN "AMJ_net_sw"
            WHEN 'Net Longwave Radiation' THEN "AMJ_net_lw"
            WHEN 'Net Radiation' THEN "AMJ_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "AMJ_1"
    ,"AMJ (% of days)"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "MJJ_solar"
            WHEN 'Net Shortwave Radiation' THEN "MJJ_net_sw"
            WHEN 'Net Longwave Radiation' THEN "MJJ_net_lw"
            WHEN 'Net Radiation' THEN "MJJ_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "MJJ_1"
    ,"MJJ (% of days)"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "JJA_solar"
            WHEN 'Net Shortwave Radiation' THEN "JJA_net_sw"
            WHEN 'Net Longwave Radiation' THEN "JJA_net_lw"
            WHEN 'Net Radiation' THEN "JJA_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "JJA_1"
    ,"JJA (% of days)"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "JAS_solar"
            WHEN 'Net Shortwave Radiation' THEN "JAS_net_sw"
            WHEN 'Net Longwave Radiation' THEN "JAS_net_lw"
            WHEN 'Net Radiation' THEN "JAS_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "JAS_1"
    ,"JAS (% of days)"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "ASO_solar"
            WHEN 'Net Shortwave Radiation' THEN "ASO_net_sw"
            WHEN 'Net Longwave Radiation' THEN "ASO_net_lw"
            WHEN 'Net Radiation' THEN "ASO_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "ASO_1"
    ,"ASO (% of days)"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "SON_solar"
            WHEN 'Net Shortwave Radiation' THEN "SON_net_sw"
            WHEN 'Net Longwave Radiation' THEN "SON_net_lw"
            WHEN 'Net Radiation' THEN "SON_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "SON_1"
    ,"SON (% of days)"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "OND_solar"
            WHEN 'Net Shortwave Radiation' THEN "OND_net_sw"
            WHEN 'Net Longwave Radiation' THEN "OND_net_lw"
            WHEN 'Net Radiation' THEN "OND_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "OND_1"
    ,"OND (% of days)"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "NDJ_solar"
            WHEN 'Net Shortwave Radiation' THEN "NDJ_net_sw"
            WHEN 'Net Longwave Radiation' THEN "NDJ_net_lw"
            WHEN 'Net Radiation' THEN "NDJ_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "NDJ_1"
    ,"NDJ (% of days)"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "DRY_solar"
            WHEN 'Net Shortwave Radiation' THEN "DRY_net_sw"
            WHEN 'Net Longwave Radiation' THEN "DRY_net_lw"
            WHEN 'Net Radiation' THEN "DRY_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "DRY_1"
    ,"DRY (% of days)"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "WET_solar"
            WHEN 'Net Shortwave Radiation' THEN "WET_net_sw"
            WHEN 'Net Longwave Radiation' THEN "WET_net_lw"
            WHEN 'Net Radiation' THEN "WET_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "WET_1"
    ,"WET (% of days)"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "ANNUAL_solar"
            WHEN 'Net Shortwave Radiation' THEN "ANNUAL_net_sw"
            WHEN 'Net Longwave Radiation' THEN "ANNUAL_net_lw"
            WHEN 'Net Radiation' THEN "ANNUAL_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "ANNUAL_1"
    ,"ANNUAL (% of days)"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN 
        CASE product
            WHEN 'Solar Radiation' THEN "DJFM_solar"
            WHEN 'Net Shortwave Radiation' THEN "DJFM_net_sw"
            WHEN 'Net Longwave Radiation' THEN "DJFM_net_lw"
            WHEN 'Net Radiation' THEN "DJFM_net"
            ELSE NULL
        END
        ELSE NULL
    END AS "DJFM_1"
    ,"DJFM (% of days)"
FROM aggregation_pct
CROSS JOIN (VALUES ('Solar Radiation'), ('Net Shortwave Radiation'), ('Net Longwave Radiation'), ('Net Radiation')) AS products(product)
ORDER BY station, year;