-- Daily data from Daily Summary
WITH daily_data AS (
    SELECT
        station_id 
        ,vr.symbol AS variable
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,min_value
        ,max_value
        ,avg_value
        ,sum_value        
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol IN ('VWC1FT', 'VWC4FT', 'PRECIP')
)
,daily_lagged_data AS (
    SELECT
        *
        ,day - 1 - LAG(day) OVER (PARTITION BY station_id, variable ORDER BY day) AS day_gap
    FROM daily_data
)
,monthly_data AS (
    SELECT
        station_id
        ,variable
        ,date_trunc('month', day::date)::date AS date
        ,EXTRACT(YEAR FROM day::date) AS year  
        ,EXTRACT(MONTH FROM day::date) AS month        
        -- Simple Month day gap
        ,MAX(day_gap) AS day_gap
        -- First Month day gap, does not count first days of the month
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (day_of_month <= {{max_day_gap}})) AS day_gap_fm
        ,COUNT(*) AS days_records_m
        ,MIN(min_value) AS min_value
        ,MAX(max_value) AS max_value
        ,AVG(avg_value) AS avg_value
        ,SUM(sum_value) AS sum_value
    FROM daily_lagged_data
    GROUP BY station_id, variable, date, year, month
)
-- SPI: monthly calculations for spi
,spi_monthly_data AS (
    SELECT
      station_id
        ,variable
        ,date
        ,year
        ,month
        ,day_gap
        ,day_gap_fm
        ,days_records_m
        ,sum_value as precip
    FROM monthly_data
    WHERE variable = 'PRECIP'
)
-- SPI: necessary dates for window calculation, e.g. 24 month
,spi_expanded_dates AS (
    SELECT {{station_id}} AS station_id, date
    FROM spi_monthly_data
    UNION
    
    SELECT {{station_id}} AS station_id, (date - (n || ' month')::INTERVAL)::DATE
    FROM spi_monthly_data CROSS JOIN generate_series(1, 24-1) AS n
)
-- SPI: data for each month, including extended
,spi_expanded_dates_data AS (
    SELECT 
        ed.station_id
        ,ed.date AS date
        ,EXTRACT(DAY FROM (DATE_TRUNC('MONTH', ed.date) + INTERVAL '1 MONTH' - INTERVAL '1 day')) AS days_m
        ,EXTRACT(MONTH FROM ed.date) AS month
        ,EXTRACT(YEAR FROM ed.date) AS year
        ,md.day_gap
        ,md.day_gap_fm
        ,COALESCE(md.days_records_m, 0) AS days_records_m
        ,md.precip
    FROM spi_expanded_dates ed
    LEFT JOIN spi_monthly_data md ON md.date = ed.date AND md.station_id = ed.station_id
)
-- SPI: calculating first month of each window
,spi_first_month AS (
    SELECT 
        *
        ,size AS window_size
        ,CASE size
            WHEN 1 THEN MIN(month) OVER w1
            WHEN 3 THEN MIN(month) OVER w3
            WHEN 6 THEN MIN(month) OVER w6
            WHEN 12 THEN MIN(month) OVER w12
            WHEN 24 THEN MIN(month) OVER w24
        END AS first_month_w
    FROM spi_expanded_dates_data
    CROSS JOIN (VALUES (1), (3), (6), (12), (24)) AS window_size(size)
    WINDOW 
        w1 AS (PARTITION BY station_id, window_size ORDER BY date ROWS BETWEEN 0 PRECEDING AND CURRENT ROW)
        ,w3 AS (PARTITION BY station_id, window_size ORDER BY date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
        ,w6 AS (PARTITION BY station_id, window_size ORDER BY date ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)
        ,w12 AS (PARTITION BY station_id, window_size ORDER BY date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)
        ,w24 AS (PARTITION BY station_id, window_size ORDER BY date ROWS BETWEEN 23 PRECEDING AND CURRENT ROW)
)
-- SPI: calculating data for each window
,spi_window_calc AS (   
    SELECT
        station_id
        ,date
        ,month
        ,year
        ,precip AS precip_m
        ,window_size
        -- Max day gap in each window
        ,CASE window_size
            WHEN 1 THEN MAX(CASE WHEN first_month_w = month THEN day_gap_fm ELSE day_gap END) OVER w1
            WHEN 3 THEN MAX(CASE WHEN first_month_w = month THEN day_gap_fm ELSE day_gap END) OVER w3
            WHEN 6 THEN MAX(CASE WHEN first_month_w = month THEN day_gap_fm ELSE day_gap END) OVER w6
            WHEN 12 THEN MAX(CASE WHEN first_month_w = month THEN day_gap_fm ELSE day_gap END) OVER w12
            WHEN 24 THEN MAX(CASE WHEN first_month_w = month THEN day_gap_fm ELSE day_gap END) OVER w24
        END AS day_gap_w
        -- Total number of days in each window
        ,CASE window_size
            WHEN 1 THEN SUM(days_m) OVER w1
            WHEN 3 THEN SUM(days_m) OVER w3
            WHEN 6 THEN SUM(days_m) OVER w6
            WHEN 12 THEN SUM(days_m) OVER w12
            WHEN 24 THEN SUM(days_m) OVER w24
        END AS days_w
        -- Number of days with records in each window
        ,CASE window_size
            WHEN 1 THEN SUM(days_records_m) OVER w1
            WHEN 3 THEN SUM(days_records_m) OVER w3
            WHEN 6 THEN SUM(days_records_m) OVER w6
            WHEN 12 THEN SUM(days_records_m) OVER w12
            WHEN 24 THEN SUM(days_records_m) OVER w24
        END AS days_records_w
        -- Computing if there are missing months in each window
        ,CASE window_size
            WHEN 1 THEN window_size = SUM(CASE WHEN days_records_m > 0 THEN 1 ELSE 0 END) OVER w1
            WHEN 3 THEN window_size = SUM(CASE WHEN days_records_m > 0 THEN 1 ELSE 0 END) OVER w3
            WHEN 6 THEN window_size = SUM(CASE WHEN days_records_m > 0 THEN 1 ELSE 0 END) OVER w6
            WHEN 12 THEN window_size = SUM(CASE WHEN days_records_m > 0 THEN 1 ELSE 0 END) OVER w12
            WHEN 24 THEN window_size = SUM(CASE WHEN days_records_m > 0 THEN 1 ELSE 0 END) OVER w24
        END AS full_w
        -- Precipitation sum for each window
        ,CASE window_size
            WHEN 1 THEN CASE WHEN window_size = SUM(CASE WHEN days_records_m > 0 THEN 1 ELSE 0 END) OVER w1 THEN SUM(precip) OVER w1 ELSE NULL END
            WHEN 3 THEN CASE WHEN window_size = SUM(CASE WHEN days_records_m > 0 THEN 1 ELSE 0 END) OVER w3 THEN SUM(precip) OVER w3 ELSE NULL END
            WHEN 6 THEN CASE WHEN window_size = SUM(CASE WHEN days_records_m > 0 THEN 1 ELSE 0 END) OVER w6 THEN SUM(precip) OVER w6 ELSE NULL END
            WHEN 12 THEN CASE WHEN window_size = SUM(CASE WHEN days_records_m > 0 THEN 1 ELSE 0 END) OVER w12 THEN SUM(precip) OVER w12 ELSE NULL END
            WHEN 24 THEN CASE WHEN window_size = SUM(CASE WHEN days_records_m > 0 THEN 1 ELSE 0 END) OVER w24 THEN SUM(precip) OVER w24 ELSE NULL END
        END AS precip_w 
    FROM spi_first_month
    WINDOW 
        w1 AS (PARTITION BY station_id, window_size ORDER BY date ROWS BETWEEN 0 PRECEDING AND CURRENT ROW)
        ,w3 AS (PARTITION BY station_id, window_size ORDER BY date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
        ,w6 AS (PARTITION BY station_id, window_size ORDER BY date ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)
        ,w12 AS (PARTITION BY station_id, window_size ORDER BY date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)
        ,w24 AS (PARTITION BY station_id, window_size ORDER BY date ROWS BETWEEN 23 PRECEDING AND CURRENT ROW)
)
-- Filtering out months wihout data
,spi_filtered AS (   
    SELECT 
        station_id
        ,date
        ,month
        ,year
        ,precip_m
        ,window_size
        ,day_gap_w
        ,ROUND(((100*days_records_w)/days_w)::numeric, 2) AS day_pct_w
        ,full_w
        ,precip_w
    FROM spi_window_calc
    WHERE precip_m IS NOT NULL
      AND year BETWEEN {{start_year}} AND {{end_year}}
)
-- SPI: calculating gamma parameters
,spi_gamma_params AS (
    SELECT 
        window_size
        ,params[1] AS k
        ,params[2] AS theta
        ,SQRT(params[1]) * params[2] AS std
        ,params[1] * params[2] AS mean
    FROM (
        SELECT 
            window_size,
            fit_gamma(ARRAY_AGG(precip_w)) AS params
        FROM spi_filtered
        GROUP BY window_size
    ) AS params
)
-- SPI: calculating spi for each window
,spi_calc AS(
    SELECT
        sf.station_id
        ,sf.month
        ,sf.year
        ,sf.precip_m
        ,sf.window_size
        ,CASE
            WHEN NOT sf.full_w THEN 'Missing Window'
            WHEN sf.day_gap_w > {{max_day_gap}} THEN 'Gap Exceeded'||sf.day_gap_w::text
            WHEN sf.day_pct_w < (100 - {{max_day_pct}}) THEN 'Pct Exceeded'
            ELSE ROUND(((sf.precip_w - sgp.mean)/sgp.std)::numeric, 2)::text
        END AS spi_precip_w
    FROM spi_filtered sf
    JOIN spi_gamma_params sgp ON sf.window_size = sgp.window_size
)
-- SPI: Final result, combining different windows into a single table
,spi_final AS (
    SELECT
        st.name AS station
        ,'SPI' AS product
        ,year
        ,month
        ,MAX(CASE WHEN window_size = 1 THEN spi_precip_w END) AS "SPI-1"
        ,MAX(CASE WHEN window_size = 3 THEN spi_precip_w END) AS "SPI-3"
        ,MAX(CASE WHEN window_size = 6 THEN spi_precip_w END) AS "SPI-6"
        ,MAX(CASE WHEN window_size = 12 THEN spi_precip_w END) AS "SPI-12"
        ,MAX(CASE WHEN window_size = 24 THEN spi_precip_w END) AS "SPI-24"
    FROM spi_calc sc
    JOIN wx_station st ON st.id = sc.station_id
    GROUP BY station, product, year, month
    ORDER BY station, year, month
)
-- SMDI: preparing monthly data for smdi
,smdi_monthly_data AS (
    SELECT
        station_id
        ,variable
        ,date
        ,month
        ,day_gap_fm AS day_gap_m
        ,ROUND((100*days_records_m/
            EXTRACT(DAY FROM (DATE_TRUNC('MONTH', date)+ INTERVAL '1 MONTH' - INTERVAL '1 day'))
        )::numeric,2) AS day_pct_m
        ,min_value AS min_soil_moisture_m
        ,max_value AS max_soil_moisture_m
        ,avg_value AS avg_soil_moisture_m
    FROM monthly_data
    WHERE variable IN ('VWC1FT', 'VWC4FT')
)
-- SMDI: calculating soild deficit
,smdi_soil_deficit_calc AS ( 
    SELECT
        md.station_id
        ,md.variable
        ,md.date
        ,md.month
        ,md.day_gap_m
        ,md.day_pct_m
        ,soil_deficit_function(md.avg_soil_moisture_m, tmd.min_soil_moisture_t, tmd.max_soil_moisture_t, tmd.avg_soil_moisture_t) AS soil_deficit
    FROM smdi_monthly_data md
    JOIN (
        SELECT
            station_id
            ,variable
            ,month
            ,MAX(max_soil_moisture_m) AS max_soil_moisture_t
            ,MIN(min_soil_moisture_m) AS min_soil_moisture_t
            ,AVG(avg_soil_moisture_m) AS avg_soil_moisture_t
        FROM smdi_monthly_data
        GROUP BY station_id, variable, month        
    ) tmd ON tmd.station_id = md.station_id
        AND tmd.month = md.month
        AND tmd.variable = md.variable
)
-- SMDI: smdi calculation
,smdi_calc AS (
    SELECT
        station_id,
        variable,
        EXTRACT(MONTH FROM date) AS month,
        EXTRACT(YEAR FROM date) AS year,
        CASE 
            WHEN day_gap_m > {{max_day_gap}} THEN 'Gap Exceeded'
            WHEN day_pct_m < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
            ELSE ROUND(smdi::numeric,2)::text
        END AS smdi_value
    FROM (
        SELECT
            station_id,
            variable,
            UNNEST(ARRAY_AGG(day_gap_m)) AS day_gap_m,
            UNNEST(ARRAY_AGG(day_pct_m)) AS day_pct_m,
            UNNEST(ARRAY_AGG(date)) AS date,
            -- Since smdi are incremental, we need to pass all array into the function
            UNNEST(smdi_function(ARRAY_AGG(soil_deficit ORDER BY date))) AS smdi
        FROM smdi_soil_deficit_calc
        GROUP BY station_id, variable
    ) t
)
--SMDI: Final result of smid, combining different soil depths
,smdi_final AS (
    SELECT
        st.name AS station
        ,'SMDI' AS product
        ,year
        ,month
        ,MAX(CASE WHEN variable = 'VWC1FT' THEN smdi_value END) AS "SMDI-1FT"
        ,MAX(CASE WHEN variable = 'VWC4FT' THEN smdi_value END) AS "SMDI-4FT"
    FROM smdi_calc sc
    JOIN wx_station st ON st.id = sc.station_id
    GROUP BY station, product, year, month
    ORDER BY station, year, month
)
SELECT
    st.name AS station
    ,'SPI and SMDI' AS product
    ,md.year
    ,md.month AS "Month"
    ,"SPI-1"
    ,"SPI-3"
    ,"SPI-6"
    ,"SPI-12"
    ,"SPI-24"
    ,"SMDI-1FT"
    ,"SMDI-4FT"
FROM (SELECT DISTINCT station_id, year, month FROM monthly_data) md
JOIN wx_station st ON st.id = md.station_id
LEFT JOIN smdi_final smdi ON smdi.station = st.name
    AND smdi.year = md.year
    AND smdi.month = md.month
LEFT JOIN spi_final spi ON spi.station = st.name
    AND spi.year = md.year
    AND spi.month = md.month
WHERE md.year BETWEEN {{start_year}} AND {{end_year}}
ORDER BY station, product, md.year, md.month