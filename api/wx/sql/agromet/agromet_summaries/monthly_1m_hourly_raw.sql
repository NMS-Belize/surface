WITH month_days AS (
    SELECT
        EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,EXTRACT(DAY FROM (DATE_TRUNC('MONTH', day) + INTERVAL '1 MONTH' - INTERVAL '1 day')) AS days_in_month        
    FROM
    (SELECT generate_series('{{ start_date }}'::date, '{{ end_date }}'::date, '1 MONTH'::interval)::date AS day) AS days
)
,daily_data AS (
    SELECT
        station_id 
        ,variable_id
        ,so.symbol AS sampling_operation
        ,DATE(datetime AT TIME ZONE '{{timezone}}') AS day
        ,EXTRACT(DAY FROM datetime AT TIME ZONE '{{timezone}}') AS day_of_month
        ,EXTRACT(MONTH FROM datetime AT TIME ZONE '{{timezone}}') AS month
        ,EXTRACT(YEAR FROM datetime AT TIME ZONE '{{timezone}}') AS year
        ,CASE so.symbol
            WHEN 'MIN' THEN MIN(min_value)
            WHEN 'MAX' THEN MAX(max_value)
            WHEN 'ACCUM' THEN SUM(sum_value)
            ELSE AVG(avg_value)
        END AS value
    FROM hourly_summary hs
    JOIN wx_variable vr ON vr.id = hs.variable_id
    JOIN wx_samplingoperation so ON so.id = vr.sampling_operation_id
    WHERE station_id = {{station_id}}
      AND variable_id IN ({{variable_ids}})
      AND datetime AT TIME ZONE '{{timezone}}' >= '{{ start_date }}'
      AND datetime AT TIME ZONE '{{timezone}}' < '{{ end_date }}'
      AND EXTRACT(MONTH FROM datetime AT TIME ZONE '{{timezone}}') IN ({{months}})
    GROUP BY station_id, variable_id, sampling_operation, day, day_of_month, month, year
)
,aggreated_data AS (
    SELECT
        st.name AS station
        ,variable_id
        ,year
        ,month
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(value)::numeric
                WHEN 'MAX' THEN MAX(value)::numeric
                WHEN 'ACCUM' THEN SUM(value)::numeric
                ELSE AVG(value)::numeric
            END, 2
        ) AS value
        ,COUNT(DISTINCT CASE WHEN (day IS NOT NULL) THEN day END) AS "count"
    FROM daily_data dd
    JOIN wx_station st ON st.id = dd.station_id
    GROUP BY st.name, variable_id, year, month, sampling_operation
)
SELECT
    station
    ,variable_id
    ,atd.year
    ,atd.month
    ,"value" AS "Aggregation"
    ,ROUND(((100*"count")::numeric/days_in_month::numeric),2) AS "Aggregation (% of days)"
FROM aggreated_data ad
LEFT JOIN month_days atd ON (atd.year=ad.year AND atd.month=ad.month) 
ORDER BY year, month