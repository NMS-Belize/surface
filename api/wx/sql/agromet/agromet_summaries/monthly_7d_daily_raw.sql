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
        ,DATE(day) AS day
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
,aggreated_data AS (
    SELECT
        st.name AS station
        ,variable_id
        ,year
        ,month
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN day_of_month BETWEEN 1 AND 7 THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN day_of_month BETWEEN 1 AND 7 THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN day_of_month BETWEEN 1 AND 7 THEN value END)::numeric
                ELSE AVG(CASE WHEN day_of_month BETWEEN 1 AND 7 THEN value END)::numeric
            END, 2
        ) AS agg_1
        ,COUNT(DISTINCT CASE WHEN ((day_of_month BETWEEN 1 AND 7) AND (day IS NOT NULL)) THEN day END) AS "agg_1_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN day_of_month BETWEEN 8 AND 14 THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN day_of_month BETWEEN 8 AND 14 THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN day_of_month BETWEEN 8 AND 14 THEN value END)::numeric
                ELSE AVG(CASE WHEN day_of_month BETWEEN 8 AND 14 THEN value END)::numeric
            END, 2
        ) AS agg_2
        ,COUNT(DISTINCT CASE WHEN ((day_of_month BETWEEN 8 AND 14) AND (day IS NOT NULL)) THEN day END) AS "agg_2_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN day_of_month BETWEEN 15 AND 21 THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN day_of_month BETWEEN 15 AND 21 THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN day_of_month BETWEEN 15 AND 21 THEN value END)::numeric
                ELSE AVG(CASE WHEN day_of_month BETWEEN 15 AND 21 THEN value END)::numeric
            END, 2
        ) AS agg_3
        ,COUNT(DISTINCT CASE WHEN ((day_of_month BETWEEN 15 AND 21) AND (day IS NOT NULL)) THEN day END) AS "agg_3_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN day_of_month >= 22 THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN day_of_month >= 22 THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN day_of_month >= 22 THEN value END)::numeric
                ELSE AVG(CASE WHEN day_of_month >= 22 THEN value END)::numeric
            END, 2
        ) AS agg_4
        ,COUNT(DISTINCT CASE WHEN ((day_of_month >= 22) AND (day IS NOT NULL)) THEN day END) AS "agg_4_count"
    FROM daily_data dd
    JOIN wx_station st ON st.id = dd.station_id
    GROUP BY st.name, variable_id, year, month, sampling_operation
)
SELECT
    station
    ,variable_id
    ,ad.year
    ,ad.month
    ,"agg_1" AS "Days 1-7"
    ,ROUND(((100*"agg_1_count")::numeric/7),2) AS "Days 1-7 (% of days)"
    ,"agg_2" AS "Days 8-14"
    ,ROUND(((100*"agg_2_count")::numeric/7),2) AS "Days 8-14 (% of days)"
    ,"agg_3" AS "Days 15-21"
    ,ROUND(((100*"agg_3_count")::numeric/7),2) AS "Days 15-21 (% of days)"
    ,"agg_4" AS "Days 22-"
    ,ROUND(((100*"agg_4_count")::numeric/(days_in_month-21)::numeric),2) AS "Days 22- (% of days)"
FROM aggreated_data ad
LEFT JOIN month_days atd ON (atd.year=ad.year AND atd.month=ad.month) 
ORDER BY year, month