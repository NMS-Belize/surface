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
        ,vr.symbol AS variable_symbol
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,max_value
        ,avg_value
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol = 'WNDSPD'
      AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
)
,extended_data AS(
    SELECT
        station_id
        ,variable_symbol
        ,day
        ,day_of_month
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
        ,CASE WHEN month IN (1, 2, 3) THEN TRUE ELSE FALSE END AS is_jfm
        ,CASE WHEN month IN (2, 3, 4) THEN TRUE ELSE FALSE END AS is_fma
        ,CASE WHEN month IN (3, 4, 5) THEN TRUE ELSE FALSE END AS is_mam
        ,CASE WHEN month IN (4, 5, 6) THEN TRUE ELSE FALSE END AS is_amj
        ,CASE WHEN month IN (5, 6, 7) THEN TRUE ELSE FALSE END AS is_mjj
        ,CASE WHEN month IN (6, 7, 8) THEN TRUE ELSE FALSE END AS is_jja
        ,CASE WHEN month IN (7, 8, 9) THEN TRUE ELSE FALSE END AS is_jas
        ,CASE WHEN month IN (8, 9, 10) THEN TRUE ELSE FALSE END AS is_aso
        ,CASE WHEN month IN (9, 10, 11) THEN TRUE ELSE FALSE END AS is_son
        ,CASE WHEN month IN (10, 11, 12) THEN TRUE ELSE FALSE END AS is_ond
        ,CASE WHEN month IN (11, 12, 13) THEN TRUE ELSE FALSE END AS is_ndj
        ,CASE WHEN month IN (0, 1, 2, 3, 4, 5) THEN TRUE ELSE FALSE END AS is_dry
        ,CASE WHEN month IN (6, 7, 8, 9, 10, 11) THEN TRUE ELSE FALSE END AS is_wet
        ,CASE WHEN month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) THEN TRUE ELSE FALSE END AS is_annual
        ,CASE WHEN month IN (0, 1, 2, 3) THEN TRUE ELSE FALSE END AS is_djfm        
        ,day - 1 - LAG(day) OVER (PARTITION BY station_id, variable_symbol, year ORDER BY day) AS day_gap
    FROM extended_data
    WHERE year BETWEEN {{start_year}} AND {{end_year}}  
)
,aggreated_data AS (
    SELECT
        st.name AS station
        ,variable_symbol
        ,year
        ,ROUND(MAX(CASE WHEN is_jfm THEN max_value END)::numeric, 2) AS "JFM_max"
        ,ROUND(AVG(CASE WHEN is_jfm THEN avg_value END)::numeric, 2) AS "JFM_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_jfm) AND (day IS NOT NULL)) THEN day END) AS "JFM_count"
        ,MAX(CASE WHEN ((is_jfm) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JFM_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_fma THEN max_value END)::numeric, 2) AS "FMA_max"
        ,ROUND(AVG(CASE WHEN is_fma THEN avg_value END)::numeric, 2) AS "FMA_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_fma) AND (day IS NOT NULL)) THEN day END) AS "FMA_count"
        ,MAX(CASE WHEN ((is_fma) AND NOT (month = 2 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "FMA_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_mam THEN max_value END)::numeric, 2) AS "MAM_max"
        ,ROUND(AVG(CASE WHEN is_mam THEN avg_value END)::numeric, 2) AS "MAM_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_mam) AND (day IS NOT NULL)) THEN day END) AS "MAM_count"
        ,MAX(CASE WHEN ((is_mam) AND NOT (month = 3 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MAM_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_amj THEN max_value END)::numeric, 2) AS "AMJ_max"
        ,ROUND(AVG(CASE WHEN is_amj THEN avg_value END)::numeric, 2) AS "AMJ_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_amj) AND (day IS NOT NULL)) THEN day END) AS "AMJ_count"
        ,MAX(CASE WHEN ((is_amj) AND NOT (month = 4 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "AMJ_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_mjj THEN max_value END)::numeric, 2) AS "MJJ_max"
        ,ROUND(AVG(CASE WHEN is_mjj THEN avg_value END)::numeric, 2) AS "MJJ_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_mjj) AND (day IS NOT NULL)) THEN day END) AS "MJJ_count"
        ,MAX(CASE WHEN ((is_mjj) AND NOT (month = 5 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MJJ_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_jja THEN max_value END)::numeric, 2) AS "JJA_max"
        ,ROUND(AVG(CASE WHEN is_jja THEN avg_value END)::numeric, 2) AS "JJA_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_jja) AND (day IS NOT NULL)) THEN day END) AS "JJA_count"
        ,MAX(CASE WHEN ((is_jja) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JJA_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_jas THEN max_value END)::numeric, 2) AS "JAS_max"
        ,ROUND(AVG(CASE WHEN is_jas THEN avg_value END)::numeric, 2) AS "JAS_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_jas) AND (day IS NOT NULL)) THEN day END) AS "JAS_count"
        ,MAX(CASE WHEN ((is_jas) AND NOT (month = 7 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JAS_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_aso THEN max_value END)::numeric, 2) AS "ASO_max"
        ,ROUND(AVG(CASE WHEN is_aso THEN avg_value END)::numeric, 2) AS "ASO_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_aso) AND (day IS NOT NULL)) THEN day END) AS "ASO_count"
        ,MAX(CASE WHEN ((is_aso) AND NOT (month = 8 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ASO_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_son THEN max_value END)::numeric, 2) AS "SON_max"
        ,ROUND(AVG(CASE WHEN is_son THEN avg_value END)::numeric, 2) AS "SON_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_son) AND (day IS NOT NULL)) THEN day END) AS "SON_count"
        ,MAX(CASE WHEN ((is_son) AND NOT (month = 9 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "SON_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_ond THEN max_value END)::numeric, 2) AS "OND_max"
        ,ROUND(AVG(CASE WHEN is_ond THEN avg_value END)::numeric, 2) AS "OND_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_ond) AND (day IS NOT NULL)) THEN day END) AS "OND_count"
        ,MAX(CASE WHEN ((is_ond) AND NOT (month = 10 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "OND_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_ndj THEN max_value END)::numeric, 2) AS "NDJ_max"
        ,ROUND(AVG(CASE WHEN is_ndj THEN avg_value END)::numeric, 2) AS "NDJ_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_ndj) AND (day IS NOT NULL)) THEN day END) AS "NDJ_count"
        ,MAX(CASE WHEN ((is_ndj) AND NOT (month = 11 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "NDJ_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_dry THEN max_value END)::numeric, 2) AS "DRY_max"
        ,ROUND(AVG(CASE WHEN is_dry THEN avg_value END)::numeric, 2) AS "DRY_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_dry) AND (day IS NOT NULL)) THEN day END) AS "DRY_count"
        ,MAX(CASE WHEN ((is_dry) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "DRY_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_wet THEN max_value END)::numeric, 2) AS "WET_max"
        ,ROUND(AVG(CASE WHEN is_wet THEN avg_value END)::numeric, 2) AS "WET_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_wet) AND (day IS NOT NULL)) THEN day END) AS "WET_count"
        ,MAX(CASE WHEN ((is_wet) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "WET_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_annual THEN max_value END)::numeric, 2) AS "ANNUAL_max"
        ,ROUND(AVG(CASE WHEN is_annual THEN avg_value END)::numeric, 2) AS "ANNUAL_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_annual) AND (day IS NOT NULL)) THEN day END) AS "ANNUAL_count"
        ,MAX(CASE WHEN ((is_annual) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ANNUAL_max_day_gap"
        ,ROUND(MAX(CASE WHEN is_djfm THEN max_value END)::numeric, 2) AS "DJFM_max"
        ,ROUND(AVG(CASE WHEN is_djfm THEN avg_value END)::numeric, 2) AS "DJFM_avg"
        ,COUNT(DISTINCT CASE WHEN ((is_djfm) AND (day IS NOT NULL)) THEN day END) AS "DJFM_count"
        ,MAX(CASE WHEN ((is_djfm) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "DJFM_max_day_gap"
    FROM daily_lagged_data dld
    JOIN wx_station st ON st.id = dld.station_id
    GROUP BY st.name, variable_symbol, year
)
,aggregation_pct AS (
    SELECT
        station
        ,variable_symbol
        ,ad.year
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_max" ELSE NULL END AS "JFM_max"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_avg" ELSE NULL END AS "JFM_avg"
        ,ROUND(((100*(CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_count" ELSE 0 END))::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_max" ELSE NULL END AS "FMA_max"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_avg" ELSE NULL END AS "FMA_avg"
        ,ROUND(((100*(CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_count" ELSE 0 END))::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_max" ELSE NULL END AS "MAM_max"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_avg" ELSE NULL END AS "MAM_avg"
        ,ROUND(((100*(CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_count" ELSE 0 END))::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_max" ELSE NULL END AS "AMJ_max"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_avg" ELSE NULL END AS "AMJ_avg"
        ,ROUND(((100*(CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_count" ELSE 0 END))::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_max" ELSE NULL END AS "MJJ_max"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_avg" ELSE NULL END AS "MJJ_avg"
        ,ROUND(((100*(CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_count" ELSE 0 END))::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_max" ELSE NULL END AS "JJA_max"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_avg" ELSE NULL END AS "JJA_avg"
        ,ROUND(((100*(CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_count" ELSE 0 END))::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_max" ELSE NULL END AS "JAS_max"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_avg" ELSE NULL END AS "JAS_avg"
        ,ROUND(((100*(CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_count" ELSE 0 END))::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_max" ELSE NULL END AS "ASO_max"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_avg" ELSE NULL END AS "ASO_avg"
        ,ROUND(((100*(CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_count" ELSE 0 END))::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_max" ELSE NULL END AS "SON_max"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_avg" ELSE NULL END AS "SON_avg"
        ,ROUND(((100*(CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_count" ELSE 0 END))::numeric/"SON_total"::numeric),2) AS "SON (% of days)"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_max" ELSE NULL END AS "OND_max"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_avg" ELSE NULL END AS "OND_avg"
        ,ROUND(((100*(CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_count" ELSE 0 END))::numeric/"OND_total"::numeric),2) AS "OND (% of days)"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_max" ELSE NULL END AS "NDJ_max"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_avg" ELSE NULL END AS "NDJ_avg"
        ,ROUND(((100*(CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_count" ELSE 0 END))::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_max" ELSE NULL END AS "DRY_max"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_avg" ELSE NULL END AS "DRY_avg"
        ,ROUND(((100*(CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_count" ELSE 0 END))::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_max" ELSE NULL END AS "WET_max"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_avg" ELSE NULL END AS "WET_avg"
        ,ROUND(((100*(CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_count" ELSE 0 END))::numeric/"WET_total"::numeric),2) AS "WET (% of days)"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_max" ELSE NULL END AS "ANNUAL_max"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_avg" ELSE NULL END AS "ANNUAL_avg"
        ,ROUND(((100*(CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_count" ELSE 0 END))::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_max" ELSE NULL END AS "DJFM_max"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_avg" ELSE NULL END AS "DJFM_avg"
        ,ROUND(((100*(CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_count" ELSE 0 END))::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"
    FROM aggreated_data ad
    LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
)
SELECT
    station
    ,variable_symbol
    ,year
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_max" ELSE NULL END AS "JFM_1"
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_avg" ELSE NULL END AS "JFM_2"
    ,"JFM (% of days)" 
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_max" ELSE NULL END AS "FMA_1"
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_avg" ELSE NULL END AS "FMA_2"
    ,"FMA (% of days)"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_max" ELSE NULL END AS "MAM_1"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_avg" ELSE NULL END AS "MAM_2"
    ,"MAM (% of days)"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_max" ELSE NULL END AS "AMJ_1"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_avg" ELSE NULL END AS "AMJ_2"
    ,"AMJ (% of days)"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_max" ELSE NULL END AS "MJJ_1"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_avg" ELSE NULL END AS "MJJ_2"
    ,"MJJ (% of days)"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_max" ELSE NULL END AS "JJA_1"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_avg" ELSE NULL END AS "JJA_2"
    ,"JJA (% of days)"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_max" ELSE NULL END AS "JAS_1"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_avg" ELSE NULL END AS "JAS_2"
    ,"JAS (% of days)"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_max" ELSE NULL END AS "ASO_1"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_avg" ELSE NULL END AS "ASO_2"
    ,"ASO (% of days)"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_max" ELSE NULL END AS "SON_1"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_avg" ELSE NULL END AS "SON_2"
    ,"SON (% of days)"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_max" ELSE NULL END AS "OND_1"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_avg" ELSE NULL END AS "OND_2"
    ,"OND (% of days)"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_max" ELSE NULL END AS "NDJ_1"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_avg" ELSE NULL END AS "NDJ_2"
    ,"NDJ (% of days)"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_max" ELSE NULL END AS "DRY_1"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_avg" ELSE NULL END AS "DRY_2"
    ,"DRY (% of days)"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_max" ELSE NULL END AS "WET_1"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_avg" ELSE NULL END AS "WET_2"
    ,"WET (% of days)"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_max" ELSE NULL END AS "ANNUAL_1"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_avg" ELSE NULL END AS "ANNUAL_2"
    ,"ANNUAL (% of days)"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_max" ELSE NULL END AS "DJFM_1"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_avg" ELSE NULL END AS "DJFM_2"
    ,"DJFM (% of days)"
FROM aggregation_pct
ORDER BY year