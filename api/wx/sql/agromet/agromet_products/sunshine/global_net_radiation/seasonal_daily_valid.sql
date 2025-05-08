-- https://www.fao.org/4/x0490e/x0490e07.htm#chapter%203%20%20%20meteorological%20data

DROP FUNCTION IF EXISTS clearsky_radiation(double precision,double precision);

-- Allen et al. (1998), FAO-56 (Equation 21).
CREATE OR REPLACE FUNCTION extraterrestrial_radiation(
    latitude float,          -- degrees (°)
    day_of_year integer      -- (1-366)
) RETURNS float AS $$        -- MJ/m²/day
DECLARE
    solar_declination float; -- radians (rad)
    inverse_relative_earth_sun_distance float; -- dimensionless
    latitude_radians float;  -- radians (rad)
    sunset_hour_angle float; -- radians (rad)
    extraterrestrial_radiation float; -- MJ/m²/day
BEGIN
    solar_declination := 0.409 * SIN((2 * PI() / 365 * day_of_year) - 1.39);
    inverse_relative_earth_sun_distance := 1 + 0.033 * COS((2 * PI() / 365) * day_of_year);
    latitude_radians := PI() / 180 * latitude;
    sunset_hour_angle := ACOS(-TAN(latitude_radians) * TAN(solar_declination));
    
    extraterrestrial_radiation := 24 * 60 / PI() * 0.0820 * inverse_relative_earth_sun_distance * 
        (sunset_hour_angle * SIN(latitude_radians) * SIN(solar_declination) + 
         COS(latitude_radians) * COS(solar_declination) * SIN(sunset_hour_angle));
    
    RETURN extraterrestrial_radiation;
END;
$$ LANGUAGE plpgsql;


-- Allen et al. (1998), FAO-56 (Equation 37).
CREATE OR REPLACE FUNCTION clearsky_radiation(
    station_elevation float, -- meters (m)
    extraterrestrial_rad float -- MJ/m²/day
) RETURNS float AS $$        -- MJ/m²/day
DECLARE
    clearsky_rad float;      -- MJ/m²/day
BEGIN
    clearsky_rad := extraterrestrial_rad * (0.75 + (2 * 10^(-5)) * station_elevation);
    RETURN clearsky_rad;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 11).
CREATE OR REPLACE FUNCTION saturation_vapour_pressure(
    t float              -- °C
) RETURNS float AS $$    -- kPa (saturation vapour pressure at T)
DECLARE
    e_t float;           -- kPa (saturation vapour pressure at T)
BEGIN
    -- Saturation vapour Pressure (e_s)
    e_t := 0.6108 * EXP((17.27 * t) / (t + 237.3));
    RETURN e_t;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 50).
-- Solar Radiation data derived from air temperature differences
CREATE OR REPLACE FUNCTION solar_radiation(
    tmax float,             -- °C
    tmin float,             -- °C
    latitude float,         -- degrees (°)
    day_of_year integer,    -- (1-366)
    inland_station boolean DEFAULT TRUE
) RETURNS float AS $$        -- MJ/m²/day
DECLARE
    extraterrestrial_rad float; -- MJ/m²/day
    solar_rad float;        -- MJ/m²/day
BEGIN
    extraterrestrial_rad := extraterrestrial_radiation(latitude, day_of_year);
    IF inland_station THEN
        solar_rad := 0.16 * SQRT(tmax - tmin) * extraterrestrial_rad;
    ELSE
        solar_rad := 0.19 * SQRT(tmax - tmin) * extraterrestrial_rad;
    END IF;
    RETURN solar_rad;
END;
$$ LANGUAGE plpgsql;


-- Allen et al. (1998), FAO-56 (Equation 38).
CREATE OR REPLACE FUNCTION net_shortwave_radiation(
    tmax float,             -- °C
    tmin float,             -- °C
    latitude float,          -- degrees (°)
    day_of_year integer,    -- (1-366)
    albedo float DEFAULT 0.23 -- dimensionless
) RETURNS float AS $$        -- MJ/m²/day
DECLARE
    solar_rad float;       -- MJ/m²/day
    net_shortwave_rad float; -- MJ/m²/day
BEGIN
    solar_rad := solar_radiation(tmax, tmin, latitude, day_of_year);
    net_shortwave_rad := (1 - albedo) * solar_rad;
    RETURN net_shortwave_rad;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 Equation 39
CREATE OR REPLACE FUNCTION net_longwave_radiation(
    tmax float,             -- °C
    tmin float,             -- °C
    latitude float,          -- degrees (°)
    station_elevation float, -- meters (m)
    day_of_year integer    -- (1-366)
) RETURNS float AS $$        -- MJ/m²/day
DECLARE
    tmin_k float;           -- Kelvin (K)
    tmax_k float;           -- Kelvin (K)
    actual_vp float;         -- kPa
    solar_rad float;        -- MJ/m²/day
    extraterrestrial_rad float; -- MJ/m²/day
    clearsky_rad float;     -- MJ/m²/day
    stefan_boltzmann_const float DEFAULT 4.903 * 10^(-9); -- MJ/K⁴/m²/day
    net_longwave_rad float; -- MJ/m²/day
BEGIN
    tmin_k := tmin + 273.16;
    tmax_k := tmax + 273.16;

    -- FAO-56 (Equation 48)
    actual_vp := saturation_vapour_pressure(tmin);

    -- FAO-56 (Equation 50) Akeisha Belize
    solar_rad := solar_radiation(tmax, tmin, latitude, day_of_year);

    -- FAO-56 (Equation 21)
    extraterrestrial_rad := extraterrestrial_radiation(latitude, day_of_year);

    -- FAO-56 (Equation 37)
    clearsky_rad := clearsky_radiation(station_elevation, extraterrestrial_rad);

    -- FAO-56 (Equation 39)
    net_longwave_rad := stefan_boltzmann_const * (
        ((POWER(tmax_k, 4) + POWER(tmin_k, 4)) / 2) *
        (0.34 - 0.14 * SQRT(actual_vp)) *
        (1.35 * (solar_rad / clearsky_rad) - 0.35)
    );

    RETURN net_longwave_rad;
END;
$$ LANGUAGE plpgsql;


-- Allen et al. (1998), FAO-56 (Equation 40).
CREATE OR REPLACE FUNCTION net_radiation(
    tmax float,             -- °C
    tmin float,             -- °C
    latitude float,          -- degrees (°)
    station_elevation float, -- meters (m)
    day_of_year integer,    -- (1-366)
    albedo float DEFAULT 0.23 -- dimensionless
) RETURNS float AS $$        -- MJ/m²/day
DECLARE
    net_shortwave_rad float; -- MJ/m²/day
    net_longwave_rad float; -- MJ/m²/day
    net_rad float; -- MJ/m²/day
BEGIN
    net_shortwave_rad := net_shortwave_radiation(tmax, tmin, latitude, day_of_year);
    net_longwave_rad := net_longwave_radiation(tmax, tmin, latitude, station_elevation, day_of_year);

    net_rad := net_shortwave_rad - net_longwave_rad;
    RETURN net_rad;
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
,daily_data AS (
    SELECT
        station_id
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,EXTRACT(DOY FROM day)::integer AS day_of_year
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,st.latitude::float AS latitude
        ,st.elevation::float AS elevation
        ,MAX(CASE WHEN vr.symbol = 'TEMPMAX' THEN max_value ELSE NULL END)::float AS tmax
        ,MIN(CASE WHEN vr.symbol = 'TEMPMIN' THEN min_value ELSE NULL END)::float AS tmin
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    JOIN wx_station st ON st.id = ds.station_id
    WHERE station_id = {{station_id}}
      AND vr.symbol IN ('TEMPMIN', 'TEMPMAX','SUNSHNHR')
      AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
    GROUP BY station_id, day, latitude, elevation
)
,extended_data AS(
    SELECT
        station_id
        ,day
        ,day_of_month
        ,day_of_year
        ,CASE 
            WHEN month=12 THEN 0
            WHEN month=1 THEN 13
        END as month
        ,CASE 
            WHEN month=12 THEN year+1
            WHEN month=1 THEN year-1
        END as year
        ,latitude
        ,elevation
        ,tmax
        ,tmin
    FROM daily_data
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM daily_data
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
        ,solar_radiation(tmax, tmin, latitude, day_of_year) AS solar_rad
        ,net_shortwave_radiation(tmax, tmin, latitude, day_of_year) AS net_shortwave_rad
        ,net_longwave_radiation(tmax, tmin, latitude, elevation, day_of_year) AS net_longwave_rad
        ,net_radiation(tmax, tmin, latitude, elevation, day_of_year) AS net_rad        
    FROM extended_data
    WHERE year BETWEEN {{start_year}} AND {{end_year}}  
      AND tmin IS NOT NULL
      AND tmax IS NOT NULL
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