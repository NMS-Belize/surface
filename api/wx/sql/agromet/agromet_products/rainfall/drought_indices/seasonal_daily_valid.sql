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

CREATE OR REPLACE FUNCTION smdi_function(sd_values float[]) 
RETURNS float[] AS $$
DECLARE
    smdi_results float[] := '{}';
    smdi_prev float := 0;
    smdi_curr float;
    sd_curr float;
BEGIN
    FOREACH sd_curr IN ARRAY sd_values LOOP
        IF sd_curr IS NULL THEN smdi_curr := NULL;
        ELSE smdi_curr := 0.5 * COALESCE(smdi_prev, 0) + (sd_curr / 50);
        END IF;

        smdi_results := smdi_results || smdi_curr;
        
        IF smdi_curr IS NOT NULL THEN smdi_prev := smdi_curr;
        END IF;
    END LOOP;
    
    RETURN smdi_results;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION smdi_function(sd_values float[]) 
RETURNS float[] AS $$
DECLARE
    smdi_results float[] := '{}';
    smdi_prev float := 0;
    smdi_curr float;
    sd_curr float;
BEGIN
    FOREACH sd_curr IN ARRAY sd_values LOOP
        IF sd_curr IS NULL THEN smdi_curr := NULL;
        ELSE smdi_curr := 0.5 * COALESCE(smdi_prev, 0) + (sd_curr / 50);
        END IF;

        smdi_results := smdi_results || smdi_curr;
        
        IF smdi_curr IS NOT NULL THEN smdi_prev := smdi_curr;
        END IF;
    END LOOP;
    
    RETURN smdi_results;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

WITH lagged_data AS (
    SELECT
        *
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,day - 1 - LAG(day) OVER (PARTITION BY station_id, variable_id ORDER BY day) AS day_gap
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol IN ('VWC1FT', 'VWC4FT', 'PRECIP')
)
,monthly_data AS (
    SELECT
        station_id
        ,symbol AS variable
        ,date_trunc('month', day::date)::date AS date
        ,EXTRACT(YEAR FROM day::date) AS year  
        ,EXTRACT(MONTH FROM day::date) AS month        
        ,MAX(day_gap) AS day_gap
        ,MAX(CASE WHEN day_of_month <= {{max_day_gap}} THEN 0 ELSE day_gap END) AS fm_day_gap
        ,COUNT(*) AS days_records_month
        ,MIN(min_value) AS min_value
        ,MAX(max_value) AS max_value
        ,AVG(avg_value) AS avg_value
        ,SUM(sum_value) AS sum_value
    FROM lagged_data
    GROUP BY station_id, variable, date, year, month
)
,spi_monthly_data AS (
    SELECT
        *
    FROM monthly_data
    WHERE variable = 'PRECIP'
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
        ,md.sum_value AS value
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
            WHEN sf.day_gap_w > {{max_day_gap}} THEN 'Gap Exceeded'||sf.day_gap_w::text
            WHEN sf.day_pct_w < (100 - {{max_day_pct}}) THEN 'Pct Exceeded'
            ELSE ROUND(((sf.value_w - sgp.mean)/sgp.std)::numeric, 2)::text
        END AS spi_value_w
    FROM spi_filtered sf
    JOIN spi_gamma_params sgp ON sf.window_size = sgp.window_size
)
,spi_final AS (
    SELECT
        st.name AS station
        ,'SPI' AS product
        ,year
        ,month
        ,MAX(CASE WHEN window_size = 1 THEN spi_value_w END) AS "SPI-1"
        ,MAX(CASE WHEN window_size = 3 THEN spi_value_w END) AS "SPI-3"
        ,MAX(CASE WHEN window_size = 6 THEN spi_value_w END) AS "SPI-6"
        ,MAX(CASE WHEN window_size = 12 THEN spi_value_w END) AS "SPI-12"
        ,MAX(CASE WHEN window_size = 24 THEN spi_value_w END) AS "SPI-24"
    FROM spi_calc sc
    JOIN wx_station st ON st.id = sc.station_id
    GROUP BY station, product, year, month
    ORDER BY station, year, month
)
,smdi_monthly_data AS (
    SELECT
        *
    FROM monthly_data
    WHERE variable IN ('VWC1FT', 'VWC4FT')
)
,smdi_soil_deficit_calc AS ( 
    SELECT
        md.station_id
        ,md.variable
        ,md.fm_day_gap
        ,ROUND((100*days_records_month/EXTRACT(DAY FROM (
            DATE_TRUNC('MONTH', md.date)+ INTERVAL '1 MONTH' - INTERVAL '1 day'
        )))::numeric,2) AS day_pct
        ,md.date
        ,md.month
        ,CASE 
            WHEN md.avg_value <= mlt.avg_value THEN 
                100*(md.avg_value - mlt.avg_value)/(mlt.avg_value - mlt.min_value)
            ELSE 100*(md.avg_value - mlt.avg_value)/(mlt.max_value - mlt.avg_value)
        END AS soil_deficit
    FROM smdi_monthly_data md
    JOIN (
        SELECT
            station_id
            ,variable
            ,month
            ,MAX(max_value) AS max_value
            ,MIN(min_value) AS min_value
            ,AVG(avg_value) AS avg_value
        FROM smdi_monthly_data
        GROUP BY station_id, variable, month        
    ) mlt ON mlt.station_id = md.station_id
        AND mlt.month = md.month
        AND mlt.variable = md.variable
)
,smdi_calc AS (
    SELECT
        station_id,
        variable,
        EXTRACT(MONTH FROM date) AS month,
        EXTRACT(YEAR FROM date) AS year,
        CASE 
            WHEN fm_day_gap > {{max_day_gap}} THEN 'Gap Exceeded'
            WHEN day_pct < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
            ELSE ROUND(smdi::numeric,2)::text
        END AS smdi_value
    FROM (
        SELECT
            station_id,
            variable,
            UNNEST(ARRAY_AGG(fm_day_gap)) AS fm_day_gap,
            UNNEST(ARRAY_AGG(day_pct)) AS day_pct,
            UNNEST(ARRAY_AGG(date)) AS date,
            UNNEST(smdi_function(ARRAY_AGG(soil_deficit ORDER BY date))) AS smdi
        FROM smdi_soil_deficit_calc
        GROUP BY station_id, variable
    ) t
)
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
