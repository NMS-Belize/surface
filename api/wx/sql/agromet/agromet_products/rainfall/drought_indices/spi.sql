DROP FUNCTION IF EXISTS fit_gamma(float[]);

CREATE OR REPLACE FUNCTION fit_gamma(value float[]) RETURNS float[] AS $$
DECLARE
    mean_val float;
    var_val float;
    mean_log float;
    n integer;
    k float;
    theta float;
    k_initial float;
    s float;
BEGIN
    -- Calculate basic statistics (only positive values)
    SELECT AVG(x), VARIANCE(x), AVG(LN(x)), COUNT(x)
    INTO mean_val, var_val, mean_log, n
    FROM unnest(value) AS x
    WHERE x > 0;
    
    -- Handle case with no positive values
    IF n = 0 OR var_val = 0 THEN
        RETURN ARRAY[NULL, NULL];
    END IF;
    
    -- Initial estimate using method of moments
    k_initial := (mean_val * mean_val) / var_val;
    k := k_initial;
    
    -- Approximation of digamma function (for positive arguments)
    -- Using the first few terms of the Taylor series expansion
    -- For more accuracy, you could implement a more complete approximation
    s := LN(mean_val) - mean_log;
    
    -- Approximate solution for k (shape parameter)
    -- Using approximation from Minka (2002) "Estimating a Gamma distribution"
    IF s < 0.5772156649 THEN  -- Euler-Mascheroni constant
        k := (0.5000876 + 0.1648852*s - 0.0544274*s*s)/s;
    ELSE
        k := (8.898919 + 9.059950*s + 0.9775373*s*s)/
             (s*(17.79728 + 11.968477*s + s*s));
    END IF;
    
    -- Calculate scale parameter
    theta := mean_val / k;
    
    RETURN ARRAY[k, theta];
END;
$$ LANGUAGE plpgsql;

WITH spi_lagged_data AS (
    SELECT
        *
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,day - 1 - LAG(day) OVER (PARTITION BY station_id, variable_id, EXTRACT(YEAR FROM day) ORDER BY day) AS day_gap
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol IN ('PRECIP')
)
,spi_monthly_data AS (
    SELECT
        station_id
        ,date_trunc('month', day::date)::date AS date
        ,MAX(day_gap) AS day_gap
        ,MAX(CASE WHEN day_of_month <= {{max_day_gap}} THEN 0 ELSE day_gap END) AS fm_day_gap
        ,COUNT(*) AS days_records_month
        ,SUM(sum_value) AS value
    FROM spi_lagged_data ld
    JOIN wx_variable vr ON vr.id = ld.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol = 'PRECIP'
    GROUP BY station_id, date
)
,spi_expanded_dates AS (
    SELECT {{station_id}} AS station_id, date
    FROM spi_monthly_data
    UNION
    
    SELECT {{station_id}} AS station_id, (date - (n || ' month')::INTERVAL)::DATE
    FROM spi_monthly_data CROSS JOIN generate_series(1, 24-1) AS n
)
,spi_expanded_dates_data AS (
    SELECT 
        ed.station_id
        ,ed.date
        ,EXTRACT(DAY FROM (DATE_TRUNC('MONTH', ed.date) + INTERVAL '1 MONTH' - INTERVAL '1 day')) AS days_month
        ,EXTRACT(MONTH FROM ed.date) AS month
        ,EXTRACT(YEAR FROM ed.date) AS year
        ,md.day_gap
        ,md.fm_day_gap
        ,COALESCE(md.days_records_month, 0) AS days_records_month
        ,md.value
    FROM spi_expanded_dates ed
    LEFT JOIN spi_monthly_data md ON md.date = ed.date AND md.station_id = ed.station_id
)
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
        END AS first_month
    FROM spi_expanded_dates_data
    CROSS JOIN (VALUES (1), (3), (6), (12), (24)) AS window_size(size)
    WINDOW 
        w1 AS (PARTITION BY station_id ORDER BY date ROWS BETWEEN 0 PRECEDING AND CURRENT ROW)
        ,w3 AS (PARTITION BY station_id ORDER BY date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
        ,w6 AS (PARTITION BY station_id ORDER BY date ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)
        ,w12 AS (PARTITION BY station_id ORDER BY date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)
        ,w24 AS (PARTITION BY station_id ORDER BY date ROWS BETWEEN 23 PRECEDING AND CURRENT ROW)
)
,spi_window_calc AS (   
    SELECT
        station_id
        ,date
        ,month
        ,year
        ,value AS raw_value
        ,window_size
        ,CASE window_size
            WHEN 1 THEN MAX(CASE WHEN first_month = month THEN fm_day_gap ELSE day_gap END) OVER w1
            WHEN 3 THEN MAX(CASE WHEN first_month = month THEN fm_day_gap ELSE day_gap END) OVER w3
            WHEN 6 THEN MAX(CASE WHEN first_month = month THEN fm_day_gap ELSE day_gap END) OVER w6
            WHEN 12 THEN MAX(CASE WHEN first_month = month THEN fm_day_gap ELSE day_gap END) OVER w12
            WHEN 24 THEN MAX(CASE WHEN first_month = month THEN fm_day_gap ELSE day_gap END) OVER w24
        END AS day_gap_w
        ,CASE window_size
            WHEN 1 THEN SUM(days_month) OVER w1
            WHEN 3 THEN SUM(days_month) OVER w3
            WHEN 6 THEN SUM(days_month) OVER w6
            WHEN 12 THEN SUM(days_month) OVER w12
            WHEN 24 THEN SUM(days_month) OVER w24
        END AS days_w
        ,CASE window_size
            WHEN 1 THEN SUM(days_records_month) OVER w1
            WHEN 3 THEN SUM(days_records_month) OVER w3
            WHEN 6 THEN SUM(days_records_month) OVER w6
            WHEN 12 THEN SUM(days_records_month) OVER w12
            WHEN 24 THEN SUM(days_records_month) OVER w24
        END AS days_records_w
        ,CASE window_size
            WHEN 1 THEN window_size = COUNT(value) OVER w1
            WHEN 3 THEN window_size = COUNT(value) OVER w3
            WHEN 6 THEN window_size = COUNT(value) OVER w6
            WHEN 12 THEN window_size = COUNT(value) OVER w12
            WHEN 24 THEN window_size = COUNT(value) OVER w24
        END AS full_w
        ,CASE window_size
            WHEN 1 THEN CASE WHEN window_size = COUNT(value) OVER w1 THEN SUM(value) OVER w1 ELSE NULL END
            WHEN 3 THEN CASE WHEN window_size = COUNT(value) OVER w3 THEN SUM(value) OVER w3 ELSE NULL END
            WHEN 6 THEN CASE WHEN window_size = COUNT(value) OVER w6 THEN SUM(value) OVER w6 ELSE NULL END
            WHEN 12 THEN CASE WHEN window_size = COUNT(value) OVER w12 THEN SUM(value) OVER w12 ELSE NULL END
            WHEN 24 THEN CASE WHEN window_size = COUNT(value) OVER w24 THEN SUM(value) OVER w24 ELSE NULL END
        END AS value_w 
    FROM spi_first_month
    WINDOW 
        w1 AS (PARTITION BY station_id ORDER BY date ROWS BETWEEN 0 PRECEDING AND CURRENT ROW)
        ,w3 AS (PARTITION BY station_id ORDER BY date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
        ,w6 AS (PARTITION BY station_id ORDER BY date ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)
        ,w12 AS (PARTITION BY station_id ORDER BY date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)
        ,w24 AS (PARTITION BY station_id ORDER BY date ROWS BETWEEN 23 PRECEDING AND CURRENT ROW)
)
,spi_filtered AS (   
    SELECT 
        station_id
        ,date
        ,month
        ,year
        ,raw_value
        ,window_size
        ,day_gap_w
        ,ROUND(((100*days_records_w)/days_w)::numeric, 2) AS day_pct_w
        ,full_w
        ,value_w
    FROM spi_window_calc
    WHERE raw_value IS NOT NULL
      AND year BETWEEN {{start_year}} AND {{end_year}}
)
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
            fit_gamma(ARRAY_AGG(value_w)) AS params
        FROM spi_filtered
        GROUP BY window_size
    ) AS params
)
,spi_calc AS(
    SELECT
        sf.station_id
        ,sf.month
        ,sf.year
        ,sf.raw_value
        ,sf.window_size
        ,CASE
            WHEN NOT sf.full_w THEN 'Missing Window'
            WHEN sf.day_gap_w > {{max_day_gap}} THEN 'Gap Exceded'
            WHEN sf.day_pct_w < (100 - {{max_day_pct}}) THEN 'Pct Exceded'
            ELSE ROUND(((sf.value_w - sgp.mean)/sgp.std)::numeric, 2)::text
        END AS spi_value_w
    FROM spi_filtered sf
    JOIN spi_gamma_params sgp ON sf.window_size = sgp.window_size
)
SELECT
    st.name AS station
    ,'SPI' AS product
    ,year
    ,month AS "Month"
    ,MAX(CASE WHEN window_size = 1 THEN spi_value_w END) AS "SPI-1"
    ,MAX(CASE WHEN window_size = 3 THEN spi_value_w END) AS "SPI-3"
    ,MAX(CASE WHEN window_size = 6 THEN spi_value_w END) AS "SPI-6"
    ,MAX(CASE WHEN window_size = 12 THEN spi_value_w END) AS "SPI-12"
    ,MAX(CASE WHEN window_size = 24 THEN spi_value_w END) AS "SPI-24"
FROM spi_calc sc
JOIN wx_station st ON st.id = sc.station_id
GROUP BY station, product, year, month
ORDER BY station, year, month;