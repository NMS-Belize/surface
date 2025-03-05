WITH month_days AS (
    SELECT
        EXTRACT(MONTH FROM day) AS month,
        EXTRACT(YEAR FROM day) AS year,        
        EXTRACT(DAY FROM (DATE_TRUNC('MONTH', day) + INTERVAL '1 MONTH' - INTERVAL '1 day')) AS days_in_month        
    FROM
    (SELECT generate_series('{{ start_date }}'::date, '{{ end_date }}'::date, '1 MONTH'::interval)::date AS day) AS days
)
,extended_month_days AS (
    SELECT
        CASE 
            WHEN month=12 THEN 0
            WHEN month=1 THEN 13
        END as month
        ,CASE 
            WHEN month=12 THEN year+1
            WHEN month=1 THEN year-1
        END as year
        ,days_in_month     
    FROM month_days
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM month_days
)
,aggreation_total_days AS(
    SELECT
        year
        ,SUM(CASE WHEN month IN (1, 2, 3) THEN days_in_month ELSE 0 END) AS "JFM_total"
        ,SUM(CASE WHEN month IN (2, 3, 4) THEN days_in_month ELSE 0 END) AS "FMA_total"
        ,SUM(CASE WHEN month IN (3, 4, 5) THEN days_in_month ELSE 0 END) AS "MAM_total"
        ,SUM(CASE WHEN month IN (4, 5, 6) THEN days_in_month ELSE 0 END) AS "AMJ_total"
        ,SUM(CASE WHEN month IN (5, 6, 7) THEN days_in_month ELSE 0 END) AS "MJJ_total"
        ,SUM(CASE WHEN month IN (6, 7, 8) THEN days_in_month ELSE 0 END) AS "JJA_total"
        ,SUM(CASE WHEN month IN (7, 8, 9) THEN days_in_month ELSE 0 END) AS "JAS_total"
        ,SUM(CASE WHEN month IN (8, 9, 10) THEN days_in_month ELSE 0 END) AS "ASO_total"
        ,SUM(CASE WHEN month IN (9, 10, 11) THEN days_in_month ELSE 0 END) AS "SON_total"
        ,SUM(CASE WHEN month IN (10, 11, 12) THEN days_in_month ELSE 0 END) AS "OND_total"
        ,SUM(CASE WHEN month IN (11, 12, 13) THEN days_in_month ELSE 0 END) AS "NDJ_total"
        ,SUM(CASE WHEN month IN (0, 1, 2, 3, 4, 5) THEN days_in_month ELSE 0 END) AS "DRY_total"
        ,SUM(CASE WHEN month IN (6, 7, 8, 9, 10, 11) THEN days_in_month ELSE 0 END) AS "WET_total"
        ,SUM(CASE WHEN month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) THEN days_in_month ELSE 0 END) AS "ANNUAL_total"
        ,SUM(CASE WHEN month IN (0, 1, 2, 3) THEN days_in_month ELSE 0 END) AS "DJFM_total"
    FROM extended_month_days
    GROUP BY year
)
,daily_data AS (
    SELECT
        station_id 
        ,variable_id
        ,so.symbol AS sampling_operation
        ,day
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
    GROUP BY station_id, variable_id, sampling_operation, day
)
,extended_data AS(
    SELECT
        station_id
        ,variable_id
        ,sampling_operation
        ,day
        ,CASE 
            WHEN month=12 THEN 0
            WHEN month=1 THEN 13
        END as month
        ,CASE 
            WHEN month=12 THEN year+1
            WHEN month=1 THEN year-1
        END as year
        ,value       
    FROM daily_data
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM daily_data
)
,aggreated_data AS (
    SELECT
        st.name AS station
        ,variable_id
        ,year
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (1, 2, 3) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (1, 2, 3) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (1, 2, 3) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (1, 2, 3) THEN value END)::numeric
            END, 2
        ) AS "JFM"
        ,COUNT(DISTINCT CASE WHEN ((month IN (1, 2, 3)) AND (day IS NOT NULL)) THEN day END) AS "JFM_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (2, 3, 4) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (2, 3, 4) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (2, 3, 4) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (2, 3, 4) THEN value END)::numeric
            END, 2
        ) AS "FMA"
        ,COUNT(DISTINCT CASE WHEN ((month IN (2, 3, 4)) AND (day IS NOT NULL)) THEN day END) AS "FMA_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (3, 4, 5) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (3, 4, 5) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (3, 4, 5) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (3, 4, 5) THEN value END)::numeric
            END, 2
        ) AS "MAM"
        ,COUNT(DISTINCT CASE WHEN ((month IN (3, 4, 5)) AND (day IS NOT NULL)) THEN day END) AS "MAM_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (4, 5, 6) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (4, 5, 6) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (4, 5, 6) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (4, 5, 6) THEN value END)::numeric
            END, 2
        ) AS "AMJ"
        ,COUNT(DISTINCT CASE WHEN ((month IN (4, 5, 6)) AND (day IS NOT NULL)) THEN day END) AS "AMJ_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (5, 6, 7) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (5, 6, 7) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (5, 6, 7) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (5, 6, 7) THEN value END)::numeric
            END, 2
        ) AS "MJJ"
        ,COUNT(DISTINCT CASE WHEN ((month IN (5, 6, 7)) AND (day IS NOT NULL)) THEN day END) AS "MJJ_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (6, 7, 8) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (6, 7, 8) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (6, 7, 8) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (6, 7, 8) THEN value END)::numeric
            END, 2
        ) AS "JJA"
        ,COUNT(DISTINCT CASE WHEN ((month IN (6, 7, 8)) AND (day IS NOT NULL)) THEN day END) AS "JJA_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (7, 8, 9) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (7, 8, 9) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (7, 8, 9) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (7, 8, 9) THEN value END)::numeric
            END, 2
        ) AS "JAS"
        ,COUNT(DISTINCT CASE WHEN ((month IN (7, 8, 9)) AND (day IS NOT NULL)) THEN day END) AS "JAS_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (8, 9, 10) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (8, 9, 10) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (8, 9, 10) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (8, 9, 10) THEN value END)::numeric
            END, 2
        ) AS "ASO"
        ,COUNT(DISTINCT CASE WHEN ((month IN (8, 9, 10)) AND (day IS NOT NULL)) THEN day END) AS "ASO_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (9, 10, 11) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (9, 10, 11) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (9, 10, 11) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (9, 10, 11) THEN value END)::numeric
            END, 2
        ) AS "SON"
        ,COUNT(DISTINCT CASE WHEN ((month IN (9, 10, 11)) AND (day IS NOT NULL)) THEN day END) AS "SON_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (10, 11, 12) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (10, 11, 12) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (10, 11, 12) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (10, 11, 12) THEN value END)::numeric
            END, 2
        ) AS "OND"
        ,COUNT(DISTINCT CASE WHEN ((month IN (10, 11, 12)) AND (day IS NOT NULL)) THEN day END) AS "OND_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (11, 12, 13) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (11, 12, 13) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (11, 12, 13) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (11, 12, 13) THEN value END)::numeric
            END, 2
        ) AS "NDJ"
        ,COUNT(DISTINCT CASE WHEN ((month IN (11, 12, 13)) AND (day IS NOT NULL)) THEN day END) AS "NDJ_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (0, 1, 2, 3, 4, 5) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (0, 1, 2, 3, 4, 5) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (0, 1, 2, 3, 4, 5) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (0, 1, 2, 3, 4, 5) THEN value END)::numeric
            END, 2
        ) AS "DRY"
        ,COUNT(DISTINCT CASE WHEN ((month IN (0, 1, 2, 3, 4, 5)) AND (day IS NOT NULL)) THEN day END) AS "DRY_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (6, 7, 8, 9, 10, 11) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (6, 7, 8, 9, 10, 11) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (6, 7, 8, 9, 10, 11) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (6, 7, 8, 9, 10, 11) THEN value END)::numeric
            END, 2
        ) AS "WET"
        ,COUNT(DISTINCT CASE WHEN ((month IN (6, 7, 8, 9, 10, 11)) AND (day IS NOT NULL)) THEN day END) AS "WET_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) THEN value END)::numeric
            END, 2
        ) AS "ANNUAL"
        ,COUNT(DISTINCT CASE WHEN ((month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)) AND (day IS NOT NULL)) THEN day END) AS "ANNUAL_count"
        ,ROUND(
            CASE sampling_operation
                WHEN 'MIN' THEN MIN(CASE WHEN month IN (0, 1, 2, 3) THEN value END)::numeric
                WHEN 'MAX' THEN MAX(CASE WHEN month IN (0, 1, 2, 3) THEN value END)::numeric
                WHEN 'ACCUM' THEN SUM(CASE WHEN month IN (0, 1, 2, 3) THEN value END)::numeric
                ELSE AVG(CASE WHEN month IN (0, 1, 2, 3) THEN value END)::numeric
            END, 2
        ) AS "DJFM"
        ,COUNT(DISTINCT CASE WHEN ((month IN (0, 1, 2, 3)) AND (day IS NOT NULL)) THEN day END) AS "DJFM_count"
    FROM extended_data ed
    JOIN wx_station st ON st.id = ed.station_id
    WHERE year BETWEEN {{start_year}} AND {{end_year}}
    GROUP BY st.name, variable_id, year, sampling_operation
)
SELECT
    station
    ,variable_id
    ,ad.year
    ,"JFM"
    ,ROUND(((100*"JFM_count")::numeric/"JFM_total"::numeric),2) AS "JFM (%)"
    ,"FMA"
    ,ROUND(((100*"FMA_count")::numeric/"FMA_total"::numeric),2) AS "FMA (%)"
    ,"MAM"
    ,ROUND(((100*"MAM_count")::numeric/"MAM_total"::numeric),2) AS "MAM (%)"
    ,"AMJ"
    ,ROUND(((100*"AMJ_count")::numeric/"AMJ_total"::numeric),2) AS "AMJ (%)"
    ,"MJJ"
    ,ROUND(((100*"MJJ_count")::numeric/"MJJ_total"::numeric),2) AS "MJJ (%)"
    ,"JJA"
    ,ROUND(((100*"JJA_count")::numeric/"JJA_total"::numeric),2) AS "JJA (%)"
    ,"JAS"
    ,ROUND(((100*"JAS_count")::numeric/"JAS_total"::numeric),2) AS "JAS (%)"
    ,"ASO"
    ,ROUND(((100*"ASO_count")::numeric/"ASO_total"::numeric),2) AS "ASO (%)"
    ,"SON"
    ,ROUND(((100*"SON_count")::numeric/"SON_total"::numeric),2) AS "SON (%)"
    ,"OND"
    ,ROUND(((100*"OND_count")::numeric/"OND_total"::numeric),2) AS "OND (%)"
    ,"NDJ"
    ,ROUND(((100*"NDJ_count")::numeric/"NDJ_total"::numeric),2) AS "NDJ (%)"
    ,"DRY"
    ,ROUND(((100*"DRY_count")::numeric/"DRY_total"::numeric),2) AS "DRY (%)"
    ,"WET"
    ,ROUND(((100*"WET_count")::numeric/"WET_total"::numeric),2) AS "WET (%)"
    ,"ANNUAL"
    ,ROUND(((100*"ANNUAL_count")::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (%)"
    ,"DJFM"
    ,ROUND(((100*"DJFM_count")::numeric/"DJFM_total"::numeric),2) AS "DJFM (%)"
FROM aggreated_data ad
LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
ORDER BY ad.year