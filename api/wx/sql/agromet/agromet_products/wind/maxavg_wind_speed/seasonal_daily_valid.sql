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
        ,day
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,max_value
        ,avg_value
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol = 'WNDSPD'
      AND day >= '{{ start_date }}'
      AND day < '{{ end_date }}'
)
,extended_data AS(
    SELECT
        station_id
        ,day
        ,CASE 
            WHEN month=12 THEN 0
            WHEN month=1 THEN 13
        END as month
        ,CASE 
            WHEN month=12 THEN year+1
            WHEN month=1 THEN year-1
        END as year
        ,max_value
        ,avg_value
    FROM daily_data
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM daily_data
)
,daily_lagged_data AS (
    SELECT
        *
        ,day - LAG(day) OVER (PARTITION BY station_id, year ORDER BY day) AS day_diff
    FROM extended_data
    WHERE year BETWEEN {{start_year}} AND {{end_year}}  
)
,aggreated_data AS (
    SELECT
        st.name AS station
        ,year
        ,ROUND(MAX(CASE WHEN month IN (1, 2, 3) THEN max_value END)::numeric, 2) AS "JFM_max"
        ,ROUND(AVG(CASE WHEN month IN (1, 2, 3) THEN avg_value END)::numeric, 2) AS "JFM_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (1, 2, 3)) AND (day IS NOT NULL)) THEN day END) AS "JFM_count"
        ,MAX(CASE
                WHEN ((month IN (1, 2, 3)) AND NOT (month = 1 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "JFM_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (2, 3, 4) THEN max_value END)::numeric, 2) AS "FMA_max"
        ,ROUND(AVG(CASE WHEN month IN (2, 3, 4) THEN avg_value END)::numeric, 2) AS "FMA_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (2, 3, 4)) AND (day IS NOT NULL)) THEN day END) AS "FMA_count"
        ,MAX(CASE
                WHEN ((month IN (2, 3, 4)) AND NOT (month = 2 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "FMA_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (3, 4, 5) THEN max_value END)::numeric, 2) AS "MAM_max"
        ,ROUND(AVG(CASE WHEN month IN (3, 4, 5) THEN avg_value END)::numeric, 2) AS "MAM_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (3, 4, 5)) AND (day IS NOT NULL)) THEN day END) AS "MAM_count"
        ,MAX(CASE
                WHEN ((month IN (3, 4, 5)) AND NOT (month = 3 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "MAM_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (4, 5, 6) THEN max_value END)::numeric, 2) AS "AMJ_max"
        ,ROUND(AVG(CASE WHEN month IN (4, 5, 6) THEN avg_value END)::numeric, 2) AS "AMJ_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (4, 5, 6)) AND (day IS NOT NULL)) THEN day END) AS "AMJ_count"
        ,MAX(CASE
                WHEN ((month IN (4, 5, 6)) AND NOT (month = 4 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "AMJ_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (5, 6, 7) THEN max_value END)::numeric, 2) AS "MJJ_max"
        ,ROUND(AVG(CASE WHEN month IN (5, 6, 7) THEN avg_value END)::numeric, 2) AS "MJJ_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (5, 6, 7)) AND (day IS NOT NULL)) THEN day END) AS "MJJ_count"
        ,MAX(CASE
                WHEN ((month IN (5, 6, 7)) AND NOT (month = 5 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "MJJ_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (6, 7, 8) THEN max_value END)::numeric, 2) AS "JJA_max"
        ,ROUND(AVG(CASE WHEN month IN (6, 7, 8) THEN avg_value END)::numeric, 2) AS "JJA_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (6, 7, 8)) AND (day IS NOT NULL)) THEN day END) AS "JJA_count"
        ,MAX(CASE
                WHEN ((month IN (6, 7, 8)) AND NOT (month = 6 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "JJA_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (7, 8, 9) THEN max_value END)::numeric, 2) AS "JAS_max"
        ,ROUND(AVG(CASE WHEN month IN (7, 8, 9) THEN avg_value END)::numeric, 2) AS "JAS_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (7, 8, 9)) AND (day IS NOT NULL)) THEN day END) AS "JAS_count"
        ,MAX(CASE
                WHEN ((month IN (7, 8, 9)) AND NOT (month = 7 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "JAS_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (8, 9, 10) THEN max_value END)::numeric, 2) AS "ASO_max"
        ,ROUND(AVG(CASE WHEN month IN (8, 9, 10) THEN avg_value END)::numeric, 2) AS "ASO_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (8, 9, 10)) AND (day IS NOT NULL)) THEN day END) AS "ASO_count"
        ,MAX(CASE
                WHEN ((month IN (8, 9, 10)) AND NOT (month = 8 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "ASO_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (9, 10, 11) THEN max_value END)::numeric, 2) AS "SON_max"
        ,ROUND(AVG(CASE WHEN month IN (9, 10, 11) THEN avg_value END)::numeric, 2) AS "SON_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (9, 10, 11)) AND (day IS NOT NULL)) THEN day END) AS "SON_count"
        ,MAX(CASE
                WHEN ((month IN (9, 10, 11)) AND NOT (month = 9 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "SON_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (10, 11, 12) THEN max_value END)::numeric, 2) AS "OND_max"
        ,ROUND(AVG(CASE WHEN month IN (10, 11, 12) THEN avg_value END)::numeric, 2) AS "OND_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (10, 11, 12)) AND (day IS NOT NULL)) THEN day END) AS "OND_count"
        ,MAX(CASE
                WHEN ((month IN (10, 11, 12)) AND NOT (month = 10 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "OND_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (11, 12, 13) THEN max_value END)::numeric, 2) AS "NDJ_max"
        ,ROUND(AVG(CASE WHEN month IN (11, 12, 13) THEN avg_value END)::numeric, 2) AS "NDJ_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (11, 12, 13)) AND (day IS NOT NULL)) THEN day END) AS "NDJ_count"
        ,MAX(CASE
                WHEN ((month IN (11, 12, 13)) AND NOT (month = 11 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "NDJ_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (0, 1, 2, 3, 4, 5) THEN max_value END)::numeric, 2) AS "DRY_max"
        ,ROUND(AVG(CASE WHEN month IN (0, 1, 2, 3, 4, 5) THEN avg_value END)::numeric, 2) AS "DRY_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (0, 1, 2, 3, 4, 5)) AND (day IS NOT NULL)) THEN day END) AS "DRY_count"
        ,MAX(CASE
                WHEN ((month IN (0, 1, 2, 3, 4, 5)) AND NOT (month = 0 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "DRY_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (6, 7, 8, 9, 10, 11) THEN max_value END)::numeric, 2) AS "WET_max"
        ,ROUND(AVG(CASE WHEN month IN (6, 7, 8, 9, 10, 11) THEN avg_value END)::numeric, 2) AS "WET_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (6, 7, 8, 9, 10, 11)) AND (day IS NOT NULL)) THEN day END) AS "WET_count"
        ,MAX(CASE
                WHEN ((month IN (6, 7, 8, 9, 10, 11)) AND NOT (month = 6 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "WET_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) THEN max_value END)::numeric, 2) AS "ANNUAL_max"
        ,ROUND(AVG(CASE WHEN month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) THEN avg_value END)::numeric, 2) AS "ANNUAL_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)) AND (day IS NOT NULL)) THEN day END) AS "ANNUAL_count"
        ,MAX(CASE
                WHEN ((month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)) AND NOT (month = 1 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "ANNUAL_max_day_diff"
        ,ROUND(MAX(CASE WHEN month IN (0, 1, 2, 3) THEN max_value END)::numeric, 2) AS "DJFM_max"
        ,ROUND(AVG(CASE WHEN month IN (0, 1, 2, 3) THEN avg_value END)::numeric, 2) AS "DJFM_avg"
        ,COUNT(DISTINCT CASE WHEN ((month IN (0, 1, 2, 3)) AND (day IS NOT NULL)) THEN day END) AS "DJFM_count"
        ,MAX(CASE
                WHEN ((month IN (0, 1, 2, 3)) AND NOT (month = 0 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "DJFM_max_day_diff"
    FROM daily_lagged_data dld
    JOIN wx_station st ON st.id = dld.station_id
    GROUP BY st.name, year
)
,aggregation_pct AS (
    SELECT
        station
        ,ad.year
        ,CASE WHEN "JFM_max_day_diff" <= ({{max_day_gap}}+1) THEN "JFM_max"||'/'||"JFM_avg" ELSE NULL END AS "JFM"
        ,ROUND(((100*(CASE WHEN "JFM_max_day_diff" <= ({{max_day_gap}}+1) THEN "JFM_count" ELSE 0 END))::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
        ,CASE WHEN "FMA_max_day_diff" <= ({{max_day_gap}}+1) THEN "FMA_max"||'/'||"FMA_avg" ELSE NULL END AS "FMA"
        ,ROUND(((100*(CASE WHEN "FMA_max_day_diff" <= ({{max_day_gap}}+1) THEN "FMA_count" ELSE 0 END))::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"
        ,CASE WHEN "MAM_max_day_diff" <= ({{max_day_gap}}+1) THEN "MAM_max"||'/'||"MAM_avg" ELSE NULL END AS "MAM"
        ,ROUND(((100*(CASE WHEN "MAM_max_day_diff" <= ({{max_day_gap}}+1) THEN "MAM_count" ELSE 0 END))::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"
        ,CASE WHEN "AMJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "AMJ_max"||'/'||"AMJ_avg" ELSE NULL END AS "AMJ"
        ,ROUND(((100*(CASE WHEN "AMJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "AMJ_count" ELSE 0 END))::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"
        ,CASE WHEN "MJJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "MJJ_max"||'/'||"MJJ_avg" ELSE NULL END AS "MJJ"
        ,ROUND(((100*(CASE WHEN "MJJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "MJJ_count" ELSE 0 END))::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"
        ,CASE WHEN "JJA_max_day_diff" <= ({{max_day_gap}}+1) THEN "JJA_max"||'/'||"JJA_avg" ELSE NULL END AS "JJA"
        ,ROUND(((100*(CASE WHEN "JJA_max_day_diff" <= ({{max_day_gap}}+1) THEN "JJA_count" ELSE 0 END))::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"
        ,CASE WHEN "JAS_max_day_diff" <= ({{max_day_gap}}+1) THEN "JAS_max"||'/'||"JAS_avg" ELSE NULL END AS "JAS"
        ,ROUND(((100*(CASE WHEN "JAS_max_day_diff" <= ({{max_day_gap}}+1) THEN "JAS_count" ELSE 0 END))::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"
        ,CASE WHEN "ASO_max_day_diff" <= ({{max_day_gap}}+1) THEN "ASO_max"||'/'||"ASO_avg" ELSE NULL END AS "ASO"
        ,ROUND(((100*(CASE WHEN "ASO_max_day_diff" <= ({{max_day_gap}}+1) THEN "ASO_count" ELSE 0 END))::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"
        ,CASE WHEN "SON_max_day_diff" <= ({{max_day_gap}}+1) THEN "SON_max"||'/'||"SON_avg" ELSE NULL END AS "SON"
        ,ROUND(((100*(CASE WHEN "SON_max_day_diff" <= ({{max_day_gap}}+1) THEN "SON_count" ELSE 0 END))::numeric/"SON_total"::numeric),2) AS "SON (% of days)"
        ,CASE WHEN "OND_max_day_diff" <= ({{max_day_gap}}+1) THEN "OND_max"||'/'||"OND_avg" ELSE NULL END AS "OND"
        ,ROUND(((100*(CASE WHEN "OND_max_day_diff" <= ({{max_day_gap}}+1) THEN "OND_count" ELSE 0 END))::numeric/"OND_total"::numeric),2) AS "OND (% of days)"
        ,CASE WHEN "NDJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "NDJ_max"||'/'||"NDJ_avg" ELSE NULL END AS "NDJ"
        ,ROUND(((100*(CASE WHEN "NDJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "NDJ_count" ELSE 0 END))::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"
        ,CASE WHEN "DRY_max_day_diff" <= ({{max_day_gap}}+1) THEN "DRY_max"||'/'||"DRY_avg" ELSE NULL END AS "DRY"
        ,ROUND(((100*(CASE WHEN "DRY_max_day_diff" <= ({{max_day_gap}}+1) THEN "DRY_count" ELSE 0 END))::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"
        ,CASE WHEN "WET_max_day_diff" <= ({{max_day_gap}}+1) THEN "WET_max"||'/'||"WET_avg" ELSE NULL END AS "WET"
        ,ROUND(((100*(CASE WHEN "WET_max_day_diff" <= ({{max_day_gap}}+1) THEN "WET_count" ELSE 0 END))::numeric/"WET_total"::numeric),2) AS "WET (% of days)"
        ,CASE WHEN "ANNUAL_max_day_diff" <= ({{max_day_gap}}+1) THEN "ANNUAL_max"||'/'||"ANNUAL_avg" ELSE NULL END AS "ANNUAL"
        ,ROUND(((100*(CASE WHEN "ANNUAL_max_day_diff" <= ({{max_day_gap}}+1) THEN "ANNUAL_count" ELSE 0 END))::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"
        ,CASE WHEN "DJFM_max_day_diff" <= ({{max_day_gap}}+1) THEN "DJFM_max"||'/'||"DJFM_avg" ELSE NULL END AS "DJFM"
        ,ROUND(((100*(CASE WHEN "DJFM_max_day_diff" <= ({{max_day_gap}}+1) THEN "DJFM_count" ELSE 0 END))::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"
    FROM aggreated_data ad
    LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
)
SELECT
    station
    ,year
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM" ELSE NULL END AS "JFM"
    ,"JFM (% of days)" 
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA" ELSE NULL END AS "FMA"
    ,"FMA (% of days)"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM" ELSE NULL END AS "MAM"
    ,"MAM (% of days)"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ" ELSE NULL END AS "AMJ"
    ,"AMJ (% of days)"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ" ELSE NULL END AS "MJJ"
    ,"MJJ (% of days)"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA" ELSE NULL END AS "JJA"
    ,"JJA (% of days)"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS" ELSE NULL END AS "JAS"
    ,"JAS (% of days)"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO" ELSE NULL END AS "ASO"
    ,"ASO (% of days)"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON" ELSE NULL END AS "SON"
    ,"SON (% of days)"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND" ELSE NULL END AS "OND"
    ,"OND (% of days)"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ" ELSE NULL END AS "NDJ"
    ,"NDJ (% of days)"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY" ELSE NULL END AS "DRY"
    ,"DRY (% of days)"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET" ELSE NULL END AS "WET"
    ,"WET (% of days)"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL" ELSE NULL END AS "ANNUAL"
    ,"ANNUAL (% of days)"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM" ELSE NULL END AS "DJFM"
    ,"DJFM (% of days)"
FROM aggregation_pct
ORDER BY year