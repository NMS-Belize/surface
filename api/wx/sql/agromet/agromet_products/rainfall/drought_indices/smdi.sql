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


WITH smdi_lagged_data AS (
    SELECT
        *
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,day - 1 - LAG(day) OVER (PARTITION BY station_id, variable_id, EXTRACT(MONTH FROM day) ORDER BY day) AS day_gap
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol IN ('VWC1FT', 'VWC4FT')
)
,smdi_monthly_data AS (
    SELECT
        station_id
        ,symbol AS variable
        ,date_trunc('month', day::date)::date AS date
        ,EXTRACT(MONTH FROM day::date) AS month        
        ,MAX(CASE WHEN day_of_month <= {{max_day_gap}} THEN 0 ELSE day_gap END) AS day_gap
        ,COUNT(*) AS days_records_month
        ,MIN(min_value) AS min_value
        ,MAX(max_value) AS max_value
        ,AVG(avg_value) AS avg_value
    FROM smdi_lagged_data
    GROUP BY station_id, variable, date, month
)
,smdi_soil_deficit_calc AS ( 
    SELECT
        md.station_id
        ,md.variable
        ,md.day_gap
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
            WHEN day_gap > {{max_day_gap}} THEN 'Gap Exceded'
            WHEN day_pct < (100-{{max_day_pct}}) THEN 'Pct Exceded'
            ELSE smdi::text
        END AS smdi_value
    FROM (
        SELECT
            station_id,
            variable,
            UNNEST(ARRAY_AGG(day_gap)) AS day_gap,
            UNNEST(ARRAY_AGG(day_pct)) AS day_pct,
            UNNEST(ARRAY_AGG(date)) AS date,
            UNNEST(smdi_function(ARRAY_AGG(soil_deficit ORDER BY date))) AS smdi
        FROM smdi_soil_deficit_calc
        GROUP BY station_id, variable
    ) t
)
SELECT 
    st.name AS station
    ,'SMDI' AS product
    ,month AS "Month"
    ,year
    ,MAX(CASE WHEN variable = 'VWC1FT' THEN smdi_value END) AS "SMDI-1FT"
    ,MAX(CASE WHEN variable = 'VWC4FT' THEN smdi_value END) AS "SMDI-4FT"    
FROM smdi_calc sc
JOIN wx_station st ON st.id = sc.station_id
WHERE year BETWEEN {{start_year}} AND {{end_year}}
GROUP BY station, product, year, month
ORDER BY station, year, month;