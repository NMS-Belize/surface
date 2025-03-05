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
        ,COUNT(DISTINCT EXTRACT(HOUR FROM datetime AT TIME ZONE '{{timezone}}')) AS total_hours
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
    GROUP BY station_id, variable_id, sampling_operation, day
)
,hourly_validated_data AS (
    SELECT
        station_id
        ,variable_id
        ,sampling_operation
        ,day
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year        
        ,value      
    FROM daily_data
    WHERE 100*total_hours >= (100-{{max_hour_pct}})*24
)
,daily_lagged_data AS (
    SELECT
        *
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,day - LAG(day) OVER (PARTITION BY station_id, variable_id, year ORDER BY day) AS day_diff
    FROM hourly_validated_data
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
                WHEN 'MIN' THEN MIN(CASE WHEN day_of_month BETWEEN 1 AND 7 THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN day_of_month BETWEEN 1 AND 7 THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN day_of_month BETWEEN 1 AND 7 THEN value END)::numeric
                ELSE AVG(CASE WHEN day_of_month BETWEEN 1 AND 7 THEN value END)::numeric
            END, 2
        ) AS agg_1
        ,COUNT(DISTINCT CASE WHEN ((day_of_month BETWEEN 1 AND 7) AND (day IS NOT NULL)) THEN day END) AS "agg_1_count"
        ,MAX(CASE WHEN ((day_of_month BETWEEN 1+({{max_day_gap}}+1) AND 7)) THEN day_diff ELSE 0 END) AS "agg_1_max_day_diff"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN day_of_month BETWEEN 8 AND 14 THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN day_of_month BETWEEN 8 AND 14 THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN day_of_month BETWEEN 8 AND 14 THEN value END)::numeric
                ELSE AVG(CASE WHEN day_of_month BETWEEN 8 AND 14 THEN value END)::numeric
            END, 2
        ) AS agg_2
        ,COUNT(DISTINCT CASE WHEN ((day_of_month BETWEEN 8 AND 14) AND (day IS NOT NULL)) THEN day END) AS "agg_2_count"
        ,MAX(CASE WHEN (day_of_month BETWEEN 8+({{max_day_gap}}+1) AND 14) THEN day_diff ELSE 0 END) AS "agg_2_max_day_diff"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN day_of_month BETWEEN 15 AND 21 THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN day_of_month BETWEEN 15 AND 21 THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN day_of_month BETWEEN 15 AND 21 THEN value END)::numeric
                ELSE AVG(CASE WHEN day_of_month BETWEEN 15 AND 21 THEN value END)::numeric
            END, 2
        ) AS agg_3
        ,COUNT(DISTINCT CASE WHEN ((day_of_month BETWEEN 15 AND 21) AND (day IS NOT NULL)) THEN day END) AS "agg_3_count"
        ,MAX(CASE WHEN (day_of_month BETWEEN 15+({{max_day_gap}}+1) AND 21) THEN day_diff ELSE 0 END) AS "agg_3_max_day_diff"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN day_of_month >= 22 THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN day_of_month >= 22 THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN day_of_month >= 22 THEN value END)::numeric
                ELSE AVG(CASE WHEN day_of_month >= 22 THEN value END)::numeric
            END, 2
        ) AS agg_4
        ,COUNT(DISTINCT CASE WHEN ((day_of_month >= 22) AND (day IS NOT NULL)) THEN day END) AS "agg_4_count"
        ,MAX(CASE WHEN (day_of_month >= 22+({{max_day_gap}}+1)) THEN day_diff ELSE 0 END) AS "agg_4_max_day_diff"
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
        ,CASE WHEN "agg_1_max_day_diff" <= ({{max_day_gap}}+1) THEN "agg_1" ELSE NULL END AS "Days 1-7"
        ,ROUND(((100*(CASE WHEN ("agg_1_max_day_diff" <= ({{max_day_gap}}+1)) THEN "agg_1_count" ELSE 0 END))::numeric/7),2) AS "Days 1-7 Day (%)"
        ,CASE WHEN "agg_2_max_day_diff" <= ({{max_day_gap}}+1) THEN "agg_2" ELSE NULL END AS "Days 8-14"
        ,ROUND(((100*(CASE WHEN ("agg_2_max_day_diff" <= ({{max_day_gap}}+1)) THEN "agg_2_count" ELSE 0 END))::numeric/7),2) AS "Days 8-14 Day (%)"
        ,CASE WHEN "agg_3_max_day_diff" <= ({{max_day_gap}}+1) THEN "agg_3" ELSE NULL END AS "Days 15-21"
        ,ROUND(((100*(CASE WHEN ("agg_3_max_day_diff" <= ({{max_day_gap}}+1)) THEN "agg_3_count" ELSE 0 END))::numeric/7),2) AS "Days 15-21 Day (%)"
        ,CASE WHEN "agg_4_max_day_diff" <= ({{max_day_gap}}+1) THEN "agg_4" ELSE NULL END AS "Days 22-"
        ,ROUND(((100*(CASE WHEN ("agg_4_max_day_diff" <= ({{max_day_gap}}+1)) THEN "agg_4_count" ELSE 0 END))::numeric/(days_in_month::numeric-21)),2) AS "Days 22- Day (%)"
    FROM aggreated_data ad
    LEFT JOIN month_days atd ON (atd.year=ad.year AND atd.month=ad.month) 
)
SELECT
    station
    ,variable_id
    ,year
    ,month
    ,CASE WHEN ("Days 1-7 Day (%)" >= (100-{{max_day_pct}})) THEN "Days 1-7" ELSE NULL END AS "Days 1-7"
    ,"Days 1-7 Day (%)"
    ,CASE WHEN ("Days 8-14 Day (%)" >= (100-{{max_day_pct}})) THEN "Days 8-14" ELSE NULL END AS "Days 8-14"
    ,"Days 8-14 Day (%)"
    ,CASE WHEN ("Days 15-21 Day (%)" >= (100-{{max_day_pct}})) THEN "Days 15-21" ELSE NULL END AS "Days 15-21"
    ,"Days 15-21 Day (%)"
    ,CASE WHEN ("Days 22- Day (%)" >= (100-{{max_day_pct}})) THEN "Days 22-" ELSE NULL END AS "Days 22-"
    ,"Days 22- Day (%)"
FROM aggregation_pct
ORDER BY year, month
