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
