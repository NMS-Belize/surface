DROP FUNCTION IF EXISTS solar_radiation(double precision,double precision,double precision,integer,boolean);

-- Allen et al. (1998), FAO-56 (Equation 21).
CREATE OR REPLACE FUNCTION extraterrestrial_radiation(
    D_r float,                     -- Dimensionless (inverse relative Earth-Sun distance) [FAO-56 Eq.23]
    omega_s float,                 -- Radians (sunset hour angle) [FAO-56 Eq.25]
    phi float,                     -- Radians (latitude) 
    delta float,                   -- Radians (solar declination) [FAO-56 Eq.24]
    G_sc float DEFAULT 0.0820      -- MJ/m²/min (solar constant) 
) RETURNS float AS $$              -- MJ/m²/day (daily extraterrestrial radiation)
DECLARE
    R_a float;                      -- MJ/m²/day (extraterrestrial radiation)
BEGIN
    R_a := ((24 * 60 )/ PI()) * G_sc * D_r * (
        omega_s * SIN(phi) * SIN(delta) + COS(phi) * COS(delta) * SIN(omega_s)
    );
    RETURN R_a;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 50).
CREATE OR REPLACE FUNCTION solar_radiation(
    tmin float,                 -- °C
    tmax float,                 -- °C
    R_a float,                  -- MJ/m²/day (extraterrestrial radiation)
    inland_station boolean DEFAULT TRUE
) RETURNS float AS $$           -- MJ/m²/day
DECLARE
    R_s float;                  -- MJ/m²/day (solar radiation)
BEGIN
    IF inland_station THEN
        R_s := 0.16 * SQRT(tmax - tmin) * R_a;
    ELSE
        R_s := 0.19 * SQRT(tmax - tmin) * R_a;
    END IF;
    RETURN R_s;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION ms_solar_radiation(
    tmin float,                 -- °C
    tmax float,                 -- °C
    latitude float,             -- degrees (°)
    day_of_year integer,        -- (1-366)
    inland_station boolean DEFAULT TRUE
) RETURNS float AS $$           -- MJ/m²/day
DECLARE
    D_r float;                     -- Dimensionless (inverse relative Earth-Sun distance) [FAO-56 Eq.23]
    omega_s float;                 -- Radians (sunset hour angle) [FAO-56 Eq.25]
    phi float;                     -- Radians (latitude) 
    delta float;                   -- Radians (solar declination) [FAO-56 Eq.24]
    R_a float;                     -- MJ/m²/day (extraterrestrial radiation)
    R_s float;                     -- MJ/m²/day (solar radiation)
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

    R_s := solar_radiation(tmin, tmax, R_a, inland_station);
    RETURN R_s;
END;
$$ LANGUAGE plpgsql;

-- Total number of days for each season and year
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
-- Daily Data from Daily Summary
,daily_data AS (
    SELECT
        station_id
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,EXTRACT(DOY FROM day)::integer AS day_of_year
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,st.latitude AS latitude
        ,MIN(CASE WHEN vr.symbol = 'TEMPMIN' THEN min_value ELSE NULL END) AS tmin
        ,MAX(CASE WHEN vr.symbol = 'TEMPMAX' THEN max_value ELSE NULL END) AS tmax
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    JOIN wx_station st ON st.id = ds.station_id
    WHERE station_id = {{station_id}}
      AND vr.symbol IN ('TEMPMIN', 'TEMPMAX','SOLARRAD')
      AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
    GROUP BY station_id, day, latitude
)
,solar_rad_calc AS (
    SELECT
        station_id
        ,day
        ,day_of_month
        ,month
        ,year
        ,ms_solar_radiation(tmin, tmax, latitude, day_of_year) AS solar_rad
    FROM daily_data
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
    FROM solar_rad_calc
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM solar_rad_calc
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
    FROM solar_rad_calc
    WHERE year BETWEEN {{start_year}} AND {{end_year}}  
)
,aggreated_data AS (
    SELECT
        st.name AS station
        ,year
        ,SUM(solar_rad) FILTER(WHERE is_jfm) AS "JFM_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_jfm) AND (day IS NOT NULL)) AS "JFM_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_jfm) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) AS "JFM_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_fma) AS "FMA_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_fma) AND (day IS NOT NULL)) AS "FMA_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_fma) AND NOT (month = 2 AND day_of_month <= {{max_day_gap}})) AS "FMA_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_mam) AS "MAM_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_mam) AND (day IS NOT NULL)) AS "MAM_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_mam) AND NOT (month = 3 AND day_of_month <= {{max_day_gap}})) AS "MAM_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_amj) AS "AMJ_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_amj) AND (day IS NOT NULL)) AS "AMJ_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_amj) AND NOT (month = 4 AND day_of_month <= {{max_day_gap}})) AS "AMJ_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_mjj) AS "MJJ_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_mjj) AND (day IS NOT NULL)) AS "MJJ_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_mjj) AND NOT (month = 5 AND day_of_month <= {{max_day_gap}})) AS "MJJ_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_jja) AS "JJA_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_jja) AND (day IS NOT NULL)) AS "JJA_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_jja) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) AS "JJA_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_jas) AS "JAS_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_jas) AND (day IS NOT NULL)) AS "JAS_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_jas) AND NOT (month = 7 AND day_of_month <= {{max_day_gap}})) AS "JAS_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_aso) AS "ASO_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_aso) AND (day IS NOT NULL)) AS "ASO_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_aso) AND NOT (month = 8 AND day_of_month <= {{max_day_gap}})) AS "ASO_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_son) AS "SON_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_son) AND (day IS NOT NULL)) AS "SON_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_son) AND NOT (month = 9 AND day_of_month <= {{max_day_gap}})) AS "SON_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_ond) AS "OND_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_ond) AND (day IS NOT NULL)) AS "OND_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_ond) AND NOT (month = 10 AND day_of_month <= {{max_day_gap}})) AS "OND_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_ndj) AS "NDJ_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_ndj) AND (day IS NOT NULL)) AS "NDJ_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_ndj) AND NOT (month = 11 AND day_of_month <= {{max_day_gap}})) AS "NDJ_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_dry) AS "DRY_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_dry) AND (day IS NOT NULL)) AS "DRY_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_dry) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) AS "DRY_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_wet) AS "WET_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_wet) AND (day IS NOT NULL)) AS "WET_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_wet) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) AS "WET_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_annual) AS "ANNUAL_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_annual) AND (day IS NOT NULL)) AS "ANNUAL_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_annual) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) AS "ANNUAL_max_day_gap"
        ,SUM(solar_rad) FILTER(WHERE is_djfm) AS "DJFM_solar_rad"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_djfm) AND (day IS NOT NULL)) AS "DJFM_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_djfm) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) AS "DJFM_max_day_gap"
    FROM daily_lagged_data dld
    JOIN wx_station st ON st.id = dld.station_id
    GROUP BY st.name, year
)
SELECT
    station
    ,'Solar Radiation' AS product
    ,ad.year
    ,CASE 
        WHEN "JFM_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("JFM_count"::numeric/"JFM_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("JFM_solar_rad"::numeric,2)::text
    END AS "JFM"
    ,ROUND(100*("JFM_count"::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
    ,CASE 
        WHEN "FMA_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("FMA_count"::numeric/"FMA_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("FMA_solar_rad"::numeric,2)::text
    END AS "FMA"
    ,ROUND(100*("FMA_count"::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"        
    ,CASE 
        WHEN "MAM_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("MAM_count"::numeric/"MAM_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("MAM_solar_rad"::numeric,2)::text
    END AS "MAM"
    ,ROUND(100*("MAM_count"::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"        
    ,CASE 
        WHEN "AMJ_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("AMJ_count"::numeric/"AMJ_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("AMJ_solar_rad"::numeric,2)::text
    END AS "AMJ"
    ,ROUND(100*("AMJ_count"::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"        
    ,CASE 
        WHEN "MJJ_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("MJJ_count"::numeric/"MJJ_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("MJJ_solar_rad"::numeric,2)::text
    END AS "MJJ"
    ,ROUND(100*("MJJ_count"::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"        
    ,CASE 
        WHEN "JJA_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("JJA_count"::numeric/"JJA_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("JJA_solar_rad"::numeric,2)::text
    END AS "JJA"
    ,ROUND(100*("JJA_count"::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"        
    ,CASE 
        WHEN "JAS_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("JAS_count"::numeric/"JAS_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("JAS_solar_rad"::numeric,2)::text
    END AS "JAS"
    ,ROUND(100*("JAS_count"::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"        
    ,CASE 
        WHEN "ASO_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("ASO_count"::numeric/"ASO_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("ASO_solar_rad"::numeric,2)::text
    END AS "ASO"
    ,ROUND(100*("ASO_count"::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"        
    ,CASE 
        WHEN "SON_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("SON_count"::numeric/"SON_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("SON_solar_rad"::numeric,2)::text
    END AS "SON"
    ,ROUND(100*("SON_count"::numeric/"SON_total"::numeric),2) AS "SON (% of days)"        
    ,CASE 
        WHEN "OND_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("OND_count"::numeric/"OND_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("OND_solar_rad"::numeric,2)::text
    END AS "OND"
    ,ROUND(100*("OND_count"::numeric/"OND_total"::numeric),2) AS "OND (% of days)"        
    ,CASE 
        WHEN "NDJ_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("NDJ_count"::numeric/"NDJ_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("NDJ_solar_rad"::numeric,2)::text
    END AS "NDJ"
    ,ROUND(100*("NDJ_count"::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"        
    ,CASE 
        WHEN "DRY_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("DRY_count"::numeric/"DRY_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("DRY_solar_rad"::numeric,2)::text
    END AS "DRY"
    ,ROUND(100*("DRY_count"::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"        
    ,CASE 
        WHEN "WET_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("WET_count"::numeric/"WET_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("WET_solar_rad"::numeric,2)::text
    END AS "WET"
    ,ROUND(100*("WET_count"::numeric/"WET_total"::numeric),2) AS "WET (% of days)"        
    ,CASE 
        WHEN "ANNUAL_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("ANNUAL_count"::numeric/"ANNUAL_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("ANNUAL_solar_rad"::numeric,2)::text
    END AS "ANNUAL"
    ,ROUND(100*("ANNUAL_count"::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"        
    ,CASE 
        WHEN "DJFM_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("DJFM_count"::numeric/"DJFM_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE ROUND("DJFM_solar_rad"::numeric,2)::text
    END AS "DJFM"
    ,ROUND(100*("DJFM_count"::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"        
FROM aggreated_data ad
LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
ORDER BY station, product, year;