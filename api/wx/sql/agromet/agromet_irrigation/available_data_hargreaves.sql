WITH daily_data AS (
    SELECT
        ds.day
        ,SUM(CASE WHEN vr.symbol = 'TEMPMIN' THEN ds.min_value END) AS temp_min
        ,SUM(CASE WHEN vr.symbol = 'TEMPMAX' THEN ds.max_value END) AS temp_max 
        ,SUM(CASE WHEN vr.symbol = 'PRECIP' THEN ds.avg_value END) AS precip
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{ station_id }}
      AND vr.symbol IN ('TEMPMAX', 'TEMPMIN','PRECIP')
      AND day >= '{{ sim_start_date }}'::date
      AND day <= '{{ sim_end_date }}'::date
    GROUP BY ds.day
    ORDER BY day
)
SELECT
    COUNT(*) AS "Days"
    ,COUNT(*) FILTER(WHERE dd.temp_min IS NOT NULL) AS "MinTempCount"
    ,MIN(dd.day) FILTER(WHERE dd.temp_min IS NOT NULL) AS "MinTempMinDay"
    ,MAX(dd.day) FILTER(WHERE dd.temp_min IS NOT NULL) AS "MinTempMaxDay"
    ,COUNT(*) FILTER(WHERE dd.temp_max IS NOT NULL) AS "MaxTempCount"
    ,MIN(dd.day) FILTER(WHERE dd.temp_max IS NOT NULL) AS "MaxTempMinDay"
    ,MAX(dd.day) FILTER(WHERE dd.temp_max IS NOT NULL) AS "MaxTempMaxDay"
    ,COUNT(*) FILTER(WHERE dd.precip IS NOT NULL) AS "PrecipitationCount"
    ,MIN(dd.day) FILTER(WHERE dd.precip IS NOT NULL) AS "PrecipitationMinDay"
    ,MAX(dd.day) FILTER(WHERE dd.precip IS NOT NULL) AS "PrecipitationMaxDay"    
FROM (SELECT generate_series('{{ sim_start_date }}'::date, '{{ sim_end_date }}'::date, '1 DAY'::interval)::date AS day) AS days
LEFT JOIN daily_data dd ON dd.day = days.day