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
        ,min_value
        ,max_value
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol IN ('TEMP', 'TEMPMIN', 'TEMPMAX')
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
        ,min_value
        ,max_value
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
        ,COUNT(CASE WHEN (is_jfm AND min_value > {{threshold}}) THEN 1 END) AS "JFM_above"
        ,COUNT(CASE WHEN ((is_jfm AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "JFM_equal"
        ,COUNT(CASE WHEN (is_jfm AND max_value < {{threshold}}) THEN 1 END) AS "JFM_below"
        ,COUNT(DISTINCT CASE WHEN ((is_jfm) AND (day IS NOT NULL)) THEN day END) AS "JFM_count"
        ,MAX(CASE WHEN ((is_jfm) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JFM_max_day_gap"
        ,COUNT(CASE WHEN (is_fma AND min_value > {{threshold}}) THEN 1 END) AS "FMA_above"
        ,COUNT(CASE WHEN ((is_fma AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "FMA_equal"
        ,COUNT(CASE WHEN (is_fma AND max_value < {{threshold}}) THEN 1 END) AS "FMA_below"
        ,COUNT(DISTINCT CASE WHEN ((is_fma) AND (day IS NOT NULL)) THEN day END) AS "FMA_count"
        ,MAX(CASE WHEN ((is_fma) AND NOT (month = 2 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "FMA_max_day_gap"
        ,COUNT(CASE WHEN (is_mam AND min_value > {{threshold}}) THEN 1 END) AS "MAM_above"
        ,COUNT(CASE WHEN ((is_mam AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "MAM_equal"
        ,COUNT(CASE WHEN (is_mam AND max_value < {{threshold}}) THEN 1 END) AS "MAM_below"
        ,COUNT(DISTINCT CASE WHEN ((is_mam) AND (day IS NOT NULL)) THEN day END) AS "MAM_count"
        ,MAX(CASE WHEN ((is_mam) AND NOT (month = 3 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MAM_max_day_gap"
        ,COUNT(CASE WHEN (is_amj AND min_value > {{threshold}}) THEN 1 END) AS "AMJ_above"
        ,COUNT(CASE WHEN ((is_amj AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "AMJ_equal"
        ,COUNT(CASE WHEN (is_amj AND max_value < {{threshold}}) THEN 1 END) AS "AMJ_below"
        ,COUNT(DISTINCT CASE WHEN ((is_amj) AND (day IS NOT NULL)) THEN day END) AS "AMJ_count"
        ,MAX(CASE WHEN ((is_amj) AND NOT (month = 4 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "AMJ_max_day_gap"
        ,COUNT(CASE WHEN (is_mjj AND min_value > {{threshold}}) THEN 1 END) AS "MJJ_above"
        ,COUNT(CASE WHEN ((is_mjj AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "MJJ_equal"
        ,COUNT(CASE WHEN (is_mjj AND max_value < {{threshold}}) THEN 1 END) AS "MJJ_below"
        ,COUNT(DISTINCT CASE WHEN ((is_mjj) AND (day IS NOT NULL)) THEN day END) AS "MJJ_count"
        ,MAX(CASE WHEN ((is_mjj) AND NOT (month = 5 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MJJ_max_day_gap"
        ,COUNT(CASE WHEN (is_jja AND min_value > {{threshold}}) THEN 1 END) AS "JJA_above"
        ,COUNT(CASE WHEN ((is_jja AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "JJA_equal"
        ,COUNT(CASE WHEN (is_jja AND max_value < {{threshold}}) THEN 1 END) AS "JJA_below"
        ,COUNT(DISTINCT CASE WHEN ((is_jja) AND (day IS NOT NULL)) THEN day END) AS "JJA_count"
        ,MAX(CASE WHEN ((is_jja) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JJA_max_day_gap"
        ,COUNT(CASE WHEN (is_jas AND min_value > {{threshold}}) THEN 1 END) AS "JAS_above"
        ,COUNT(CASE WHEN ((is_jas AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "JAS_equal"
        ,COUNT(CASE WHEN (is_jas AND max_value < {{threshold}}) THEN 1 END) AS "JAS_below"
        ,COUNT(DISTINCT CASE WHEN ((is_jas) AND (day IS NOT NULL)) THEN day END) AS "JAS_count"
        ,MAX(CASE WHEN ((is_jas) AND NOT (month = 7 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JAS_max_day_gap"
        ,COUNT(CASE WHEN (is_aso AND min_value > {{threshold}}) THEN 1 END) AS "ASO_above"
        ,COUNT(CASE WHEN ((is_aso AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "ASO_equal"
        ,COUNT(CASE WHEN (is_aso AND max_value < {{threshold}}) THEN 1 END) AS "ASO_below"
        ,COUNT(DISTINCT CASE WHEN ((is_aso) AND (day IS NOT NULL)) THEN day END) AS "ASO_count"
        ,MAX(CASE WHEN ((is_aso) AND NOT (month = 8 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ASO_max_day_gap"
        ,COUNT(CASE WHEN (is_son AND min_value > {{threshold}}) THEN 1 END) AS "SON_above"
        ,COUNT(CASE WHEN ((is_son AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "SON_equal"
        ,COUNT(CASE WHEN (is_son AND max_value < {{threshold}}) THEN 1 END) AS "SON_below"
        ,COUNT(DISTINCT CASE WHEN ((is_son) AND (day IS NOT NULL)) THEN day END) AS "SON_count"
        ,MAX(CASE WHEN ((is_son) AND NOT (month = 9 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "SON_max_day_gap"
        ,COUNT(CASE WHEN (is_ond AND min_value > {{threshold}}) THEN 1 END) AS "OND_above"
        ,COUNT(CASE WHEN ((is_ond AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "OND_equal"
        ,COUNT(CASE WHEN (is_ond AND max_value < {{threshold}}) THEN 1 END) AS "OND_below"
        ,COUNT(DISTINCT CASE WHEN ((is_ond) AND (day IS NOT NULL)) THEN day END) AS "OND_count"
        ,MAX(CASE WHEN ((is_ond) AND NOT (month = 10 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "OND_max_day_gap"
        ,COUNT(CASE WHEN (is_ndj AND min_value > {{threshold}}) THEN 1 END) AS "NDJ_above"
        ,COUNT(CASE WHEN ((is_ndj AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "NDJ_equal"
        ,COUNT(CASE WHEN (is_ndj AND max_value < {{threshold}}) THEN 1 END) AS "NDJ_below"
        ,COUNT(DISTINCT CASE WHEN ((is_ndj) AND (day IS NOT NULL)) THEN day END) AS "NDJ_count"
        ,MAX(CASE WHEN ((is_ndj) AND NOT (month = 11 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "NDJ_max_day_gap"
        ,COUNT(CASE WHEN (is_dry AND min_value > {{threshold}}) THEN 1 END) AS "DRY_above"
        ,COUNT(CASE WHEN ((is_dry AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "DRY_equal"
        ,COUNT(CASE WHEN (is_dry AND max_value < {{threshold}}) THEN 1 END) AS "DRY_below"
        ,COUNT(DISTINCT CASE WHEN ((is_dry) AND (day IS NOT NULL)) THEN day END) AS "DRY_count"
        ,MAX(CASE WHEN ((is_dry) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "DRY_max_day_gap"
        ,COUNT(CASE WHEN (is_wet AND min_value > {{threshold}}) THEN 1 END) AS "WET_above"
        ,COUNT(CASE WHEN ((is_wet AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "WET_equal"
        ,COUNT(CASE WHEN (is_wet AND max_value < {{threshold}}) THEN 1 END) AS "WET_below"
        ,COUNT(DISTINCT CASE WHEN ((is_wet) AND (day IS NOT NULL)) THEN day END) AS "WET_count"
        ,MAX(CASE WHEN ((is_wet) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "WET_max_day_gap"
        ,COUNT(CASE WHEN (is_annual AND min_value > {{threshold}}) THEN 1 END) AS "ANNUAL_above"
        ,COUNT(CASE WHEN ((is_annual AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "ANNUAL_equal"
        ,COUNT(CASE WHEN (is_annual AND max_value < {{threshold}}) THEN 1 END) AS "ANNUAL_below"
        ,COUNT(DISTINCT CASE WHEN ((is_annual) AND (day IS NOT NULL)) THEN day END) AS "ANNUAL_count"
        ,MAX(CASE WHEN ((is_annual) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ANNUAL_max_day_gap"
        ,COUNT(CASE WHEN (is_djfm AND min_value > {{threshold}}) THEN 1 END) AS "DJFM_above"
        ,COUNT(CASE WHEN ((is_djfm AND ({{threshold}}) BETWEEN min_value AND max_value)) THEN 1 END) AS "DJFM_equal"
        ,COUNT(CASE WHEN (is_djfm AND max_value < {{threshold}}) THEN 1 END) AS "DJFM_below"
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
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_below" ELSE NULL END AS "JFM_below"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_equal" ELSE NULL END AS "JFM_equal"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_above" ELSE NULL END AS "JFM_above"
        ,ROUND(((100*(CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_count" ELSE 0 END))::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_below" ELSE NULL END AS "FMA_below"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_equal" ELSE NULL END AS "FMA_equal"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_above" ELSE NULL END AS "FMA_above"
        ,ROUND(((100*(CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_count" ELSE 0 END))::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_below" ELSE NULL END AS "MAM_below"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_equal" ELSE NULL END AS "MAM_equal"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_above" ELSE NULL END AS "MAM_above"
        ,ROUND(((100*(CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_count" ELSE 0 END))::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_below" ELSE NULL END AS "AMJ_below"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_equal" ELSE NULL END AS "AMJ_equal"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_above" ELSE NULL END AS "AMJ_above"
        ,ROUND(((100*(CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_count" ELSE 0 END))::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_below" ELSE NULL END AS "MJJ_below"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_equal" ELSE NULL END AS "MJJ_equal"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_above" ELSE NULL END AS "MJJ_above"
        ,ROUND(((100*(CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_count" ELSE 0 END))::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_below" ELSE NULL END AS "JJA_below"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_equal" ELSE NULL END AS "JJA_equal"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_above" ELSE NULL END AS "JJA_above"
        ,ROUND(((100*(CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_count" ELSE 0 END))::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_below" ELSE NULL END AS "JAS_below"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_equal" ELSE NULL END AS "JAS_equal"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_above" ELSE NULL END AS "JAS_above"
        ,ROUND(((100*(CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_count" ELSE 0 END))::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_below" ELSE NULL END AS "ASO_below"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_equal" ELSE NULL END AS "ASO_equal"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_above" ELSE NULL END AS "ASO_above"
        ,ROUND(((100*(CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_count" ELSE 0 END))::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_below" ELSE NULL END AS "SON_below"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_equal" ELSE NULL END AS "SON_equal"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_above" ELSE NULL END AS "SON_above"
        ,ROUND(((100*(CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_count" ELSE 0 END))::numeric/"SON_total"::numeric),2) AS "SON (% of days)"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_below" ELSE NULL END AS "OND_below"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_equal" ELSE NULL END AS "OND_equal"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_above" ELSE NULL END AS "OND_above"
        ,ROUND(((100*(CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_count" ELSE 0 END))::numeric/"OND_total"::numeric),2) AS "OND (% of days)"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_below" ELSE NULL END AS "NDJ_below"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_equal" ELSE NULL END AS "NDJ_equal"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_above" ELSE NULL END AS "NDJ_above"
        ,ROUND(((100*(CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_count" ELSE 0 END))::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_below" ELSE NULL END AS "DRY_below"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_equal" ELSE NULL END AS "DRY_equal"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_above" ELSE NULL END AS "DRY_above"
        ,ROUND(((100*(CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_count" ELSE 0 END))::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_below" ELSE NULL END AS "WET_below"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_equal" ELSE NULL END AS "WET_equal"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_above" ELSE NULL END AS "WET_above"
        ,ROUND(((100*(CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_count" ELSE 0 END))::numeric/"WET_total"::numeric),2) AS "WET (% of days)"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_below" ELSE NULL END AS "ANNUAL_below"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_equal" ELSE NULL END AS "ANNUAL_equal"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_above" ELSE NULL END AS "ANNUAL_above"
        ,ROUND(((100*(CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_count" ELSE 0 END))::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_below" ELSE NULL END AS "DJFM_below"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_equal" ELSE NULL END AS "DJFM_equal"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_above" ELSE NULL END AS "DJFM_above"
        ,ROUND(((100*(CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_count" ELSE 0 END))::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"
    FROM aggreated_data ad
    LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
)
SELECT
    station
    ,variable_symbol
    ,year
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_below" ELSE NULL END AS "JFM_1"
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_equal" ELSE NULL END AS "JFM_2"
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_above" ELSE NULL END AS "JFM_3"
    ,"JFM (% of days)" 
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_below" ELSE NULL END AS "FMA_1"
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_equal" ELSE NULL END AS "FMA_2"
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_above" ELSE NULL END AS "FMA_3"
    ,"FMA (% of days)"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_below" ELSE NULL END AS "MAM_1"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_equal" ELSE NULL END AS "MAM_2"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_above" ELSE NULL END AS "MAM_3"
    ,"MAM (% of days)"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_below" ELSE NULL END AS "AMJ_1"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_equal" ELSE NULL END AS "AMJ_2"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_above" ELSE NULL END AS "AMJ_3"
    ,"AMJ (% of days)"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_below" ELSE NULL END AS "MJJ_1"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_equal" ELSE NULL END AS "MJJ_2"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_above" ELSE NULL END AS "MJJ_3"
    ,"MJJ (% of days)"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_below" ELSE NULL END AS "JJA_1"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_equal" ELSE NULL END AS "JJA_2"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_above" ELSE NULL END AS "JJA_3"
    ,"JJA (% of days)"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_below" ELSE NULL END AS "JAS_1"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_equal" ELSE NULL END AS "JAS_2"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_above" ELSE NULL END AS "JAS_3"
    ,"JAS (% of days)"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_below" ELSE NULL END AS "ASO_1"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_equal" ELSE NULL END AS "ASO_2"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_above" ELSE NULL END AS "ASO_3"
    ,"ASO (% of days)"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_below" ELSE NULL END AS "SON_1"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_equal" ELSE NULL END AS "SON_2"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_above" ELSE NULL END AS "SON_3"
    ,"SON (% of days)"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_below" ELSE NULL END AS "OND_1"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_equal" ELSE NULL END AS "OND_2"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_above" ELSE NULL END AS "OND_3"
    ,"OND (% of days)"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_below" ELSE NULL END AS "NDJ_1"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_equal" ELSE NULL END AS "NDJ_2"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_above" ELSE NULL END AS "NDJ_3"
    ,"NDJ (% of days)"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_below" ELSE NULL END AS "DRY_1"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_equal" ELSE NULL END AS "DRY_2"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_above" ELSE NULL END AS "DRY_3"
    ,"DRY (% of days)"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_below" ELSE NULL END AS "WET_1"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_equal" ELSE NULL END AS "WET_2"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_above" ELSE NULL END AS "WET_3"
    ,"WET (% of days)"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_below" ELSE NULL END AS "ANNUAL_1"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_equal" ELSE NULL END AS "ANNUAL_2"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_above" ELSE NULL END AS "ANNUAL_3"
    ,"ANNUAL (% of days)"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_below" ELSE NULL END AS "DJFM_1"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_equal" ELSE NULL END AS "DJFM_2"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_above" ELSE NULL END AS "DJFM_3"
    ,"DJFM (% of days)"
FROM aggregation_pct
ORDER BY year