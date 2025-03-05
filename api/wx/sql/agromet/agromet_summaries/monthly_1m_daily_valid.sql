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
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month        
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year              
        ,CASE so.symbol
            WHEN 'MIN' THEN MIN(min_value)
            WHEN 'MAX' THEN MAX(max_value)
            WHEN 'ACCUM' THEN SUM(sum_value)
            ELSE AVG(avg_value)
        END AS value
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    JOIN wx_samplingoperation so ON so.id = vr.sampling_operation_id
    WHERE station_id = {{station_id}}
      AND variable_id IN ({{variable_ids}})
      AND day >= '{{ start_date }}'
      AND day < '{{ end_date }}'
      AND EXTRACT(MONTH FROM day) IN ({{months}})
    GROUP BY station_id, variable_id, sampling_operation, day, day_of_month, month, year
)
,daily_lagged_data AS (
    SELECT
        *
        ,day - LAG(day) OVER (PARTITION BY station_id, variable_id, year ORDER BY day) AS day_diff
    FROM daily_data
    WHERE year BETWEEN {{start_year}} AND {{end_year}}  
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
        ,MAX(CASE WHEN (day_of_month >= ({{max_day_gap}}+1)) THEN day_diff ELSE NULL END) AS "max_day_diff"
    FROM daily_lagged_data dld
    JOIN wx_station st ON st.id = dld.station_id
    GROUP BY st.name, variable_id, year, month, sampling_operation
)
,aggregation_pct AS (
    SELECT
        station
        ,variable_id
        ,ad.year
        ,ad.month
        ,CASE WHEN ("max_day_diff" <= ({{max_day_gap}}+1)) THEN "value" ELSE NULL END AS "Aggregation"
        ,ROUND(((100*(CASE WHEN ("max_day_diff" <= ({{max_day_gap}}+1)) THEN "count" ELSE 0 END))::numeric/days_in_month::numeric),2) AS "Aggregation (% of days)"
    FROM aggreated_data ad
    LEFT JOIN month_days atd ON (atd.year=ad.year AND atd.month=ad.month) 
)
SELECT
    station
    ,variable_id
    ,year
    ,month
    ,CASE WHEN "Aggregation (% of days)" >= (100-{{max_day_pct}}) THEN "Aggregation" ELSE NULL END AS "Aggregation"
    ,"Aggregation (% of days)"
FROM aggregation_pct
ORDER BY year, month

