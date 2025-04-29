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
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,sum_value AS value
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol = 'PRECIP'
      AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
)
,extended_data AS(
    SELECT
        station_id
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
        ,value
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
        ,day - 1 - LAG(day) OVER (PARTITION BY station_id, year ORDER BY day) AS day_gap
    FROM extended_data
    WHERE year BETWEEN {{start_year}} AND {{end_year}}  
)
,aggreated_data AS (
    SELECT
        st.name AS station
        ,year
        ,COUNT(*) FILTER(WHERE is_jfm AND value > 25) AS "JFM_25"
        ,COUNT(*) FILTER(WHERE is_jfm AND value > 50) AS "JFM_50"
        ,COUNT(*) FILTER(WHERE is_jfm AND value > 84) AS "JFM_84"
        ,COUNT(*) FILTER(WHERE is_jfm AND value > 200) AS "JFM_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_jfm AND (day IS NOT NULL)) AS "JFM_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_jfm) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) AS "JFM_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_fma AND value > 25) AS "FMA_25"
        ,COUNT(*) FILTER(WHERE is_fma AND value > 50) AS "FMA_50"
        ,COUNT(*) FILTER(WHERE is_fma AND value > 84) AS "FMA_84"
        ,COUNT(*) FILTER(WHERE is_fma AND value > 200) AS "FMA_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_fma AND (day IS NOT NULL)) AS "FMA_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_fma) AND NOT (month = 2 AND day_of_month <= {{max_day_gap}})) AS "FMA_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_mam AND value > 25) AS "MAM_25"
        ,COUNT(*) FILTER(WHERE is_mam AND value > 50) AS "MAM_50"
        ,COUNT(*) FILTER(WHERE is_mam AND value > 84) AS "MAM_84"
        ,COUNT(*) FILTER(WHERE is_mam AND value > 200) AS "MAM_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_mam AND (day IS NOT NULL)) AS "MAM_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_mam) AND NOT (month = 3 AND day_of_month <= {{max_day_gap}})) AS "MAM_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_amj AND value > 25) AS "AMJ_25"
        ,COUNT(*) FILTER(WHERE is_amj AND value > 50) AS "AMJ_50"
        ,COUNT(*) FILTER(WHERE is_amj AND value > 84) AS "AMJ_84"
        ,COUNT(*) FILTER(WHERE is_amj AND value > 200) AS "AMJ_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_amj AND (day IS NOT NULL)) AS "AMJ_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_amj) AND NOT (month = 4 AND day_of_month <= {{max_day_gap}})) AS "AMJ_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_mjj AND value > 25) AS "MJJ_25"
        ,COUNT(*) FILTER(WHERE is_mjj AND value > 50) AS "MJJ_50"
        ,COUNT(*) FILTER(WHERE is_mjj AND value > 84) AS "MJJ_84"
        ,COUNT(*) FILTER(WHERE is_mjj AND value > 200) AS "MJJ_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_mjj AND (day IS NOT NULL)) AS "MJJ_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_mjj) AND NOT (month = 5 AND day_of_month <= {{max_day_gap}})) AS "MJJ_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_jja AND value > 25) AS "JJA_25"
        ,COUNT(*) FILTER(WHERE is_jja AND value > 50) AS "JJA_50"
        ,COUNT(*) FILTER(WHERE is_jja AND value > 84) AS "JJA_84"
        ,COUNT(*) FILTER(WHERE is_jja AND value > 200) AS "JJA_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_jja AND (day IS NOT NULL)) AS "JJA_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_jja) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) AS "JJA_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_jas AND value > 25) AS "JAS_25"
        ,COUNT(*) FILTER(WHERE is_jas AND value > 50) AS "JAS_50"
        ,COUNT(*) FILTER(WHERE is_jas AND value > 84) AS "JAS_84"
        ,COUNT(*) FILTER(WHERE is_jas AND value > 200) AS "JAS_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_jas AND (day IS NOT NULL)) AS "JAS_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_jas) AND NOT (month = 7 AND day_of_month <= {{max_day_gap}})) AS "JAS_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_aso AND value > 25) AS "ASO_25"
        ,COUNT(*) FILTER(WHERE is_aso AND value > 50) AS "ASO_50"
        ,COUNT(*) FILTER(WHERE is_aso AND value > 84) AS "ASO_84"
        ,COUNT(*) FILTER(WHERE is_aso AND value > 200) AS "ASO_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_aso AND (day IS NOT NULL)) AS "ASO_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_aso) AND NOT (month = 8 AND day_of_month <= {{max_day_gap}})) AS "ASO_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_son AND value > 25) AS "SON_25"
        ,COUNT(*) FILTER(WHERE is_son AND value > 50) AS "SON_50"
        ,COUNT(*) FILTER(WHERE is_son AND value > 84) AS "SON_84"
        ,COUNT(*) FILTER(WHERE is_son AND value > 200) AS "SON_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_son AND (day IS NOT NULL)) AS "SON_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_son) AND NOT (month = 9 AND day_of_month <= {{max_day_gap}})) AS "SON_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_ond AND value > 25) AS "OND_25"
        ,COUNT(*) FILTER(WHERE is_ond AND value > 50) AS "OND_50"
        ,COUNT(*) FILTER(WHERE is_ond AND value > 84) AS "OND_84"
        ,COUNT(*) FILTER(WHERE is_ond AND value > 200) AS "OND_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_ond AND (day IS NOT NULL)) AS "OND_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_ond) AND NOT (month = 10 AND day_of_month <= {{max_day_gap}})) AS "OND_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_ndj AND value > 25) AS "NDJ_25"
        ,COUNT(*) FILTER(WHERE is_ndj AND value > 50) AS "NDJ_50"
        ,COUNT(*) FILTER(WHERE is_ndj AND value > 84) AS "NDJ_84"
        ,COUNT(*) FILTER(WHERE is_ndj AND value > 200) AS "NDJ_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_ndj AND (day IS NOT NULL)) AS "NDJ_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_ndj) AND NOT (month = 11 AND day_of_month <= {{max_day_gap}})) AS "NDJ_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_dry AND value > 25) AS "DRY_25"
        ,COUNT(*) FILTER(WHERE is_dry AND value > 50) AS "DRY_50"
        ,COUNT(*) FILTER(WHERE is_dry AND value > 84) AS "DRY_84"
        ,COUNT(*) FILTER(WHERE is_dry AND value > 200) AS "DRY_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_dry AND (day IS NOT NULL)) AS "DRY_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_dry) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) AS "DRY_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_wet AND value > 25) AS "WET_25"
        ,COUNT(*) FILTER(WHERE is_wet AND value > 50) AS "WET_50"
        ,COUNT(*) FILTER(WHERE is_wet AND value > 84) AS "WET_84"
        ,COUNT(*) FILTER(WHERE is_wet AND value > 200) AS "WET_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_wet AND (day IS NOT NULL)) AS "WET_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_wet) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) AS "WET_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_annual AND value > 25) AS "ANNUAL_25"
        ,COUNT(*) FILTER(WHERE is_annual AND value > 50) AS "ANNUAL_50"
        ,COUNT(*) FILTER(WHERE is_annual AND value > 84) AS "ANNUAL_84"
        ,COUNT(*) FILTER(WHERE is_annual AND value > 200) AS "ANNUAL_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_annual AND (day IS NOT NULL)) AS "ANNUAL_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_annual) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) AS "ANNUAL_max_day_gap"
        ,COUNT(*) FILTER(WHERE is_djfm AND value > 25) AS "DJFM_25"
        ,COUNT(*) FILTER(WHERE is_djfm AND value > 50) AS "DJFM_50"
        ,COUNT(*) FILTER(WHERE is_djfm AND value > 84) AS "DJFM_84"
        ,COUNT(*) FILTER(WHERE is_djfm AND value > 200) AS "DJFM_200"
        ,COUNT(DISTINCT day) FILTER(WHERE is_djfm AND (day IS NOT NULL)) AS "DJFM_count"
        ,MAX(COALESCE(day_gap, 0)) FILTER(WHERE (is_djfm) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) AS "DJFM_max_day_gap"
    FROM daily_lagged_data dld
    JOIN wx_station st ON st.id = dld.station_id
    GROUP BY st.name, year
)
,aggregation_pct AS (
    SELECT
        station
        ,ad.year
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_25" ELSE NULL END AS "JFM_25"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_50" ELSE NULL END AS "JFM_50"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_84" ELSE NULL END AS "JFM_84"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_200" ELSE NULL END AS "JFM_200"
        ,ROUND(((100*(CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_count" ELSE 0 END))::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_25" ELSE NULL END AS "FMA_25"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_50" ELSE NULL END AS "FMA_50"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_84" ELSE NULL END AS "FMA_84"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_200" ELSE NULL END AS "FMA_200"
        ,ROUND(((100*(CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_count" ELSE 0 END))::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_25" ELSE NULL END AS "MAM_25"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_50" ELSE NULL END AS "MAM_50"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_84" ELSE NULL END AS "MAM_84"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_200" ELSE NULL END AS "MAM_200"
        ,ROUND(((100*(CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_count" ELSE 0 END))::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_25" ELSE NULL END AS "AMJ_25"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_50" ELSE NULL END AS "AMJ_50"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_84" ELSE NULL END AS "AMJ_84"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_200" ELSE NULL END AS "AMJ_200"
        ,ROUND(((100*(CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_count" ELSE 0 END))::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_25" ELSE NULL END AS "MJJ_25"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_50" ELSE NULL END AS "MJJ_50"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_84" ELSE NULL END AS "MJJ_84"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_200" ELSE NULL END AS "MJJ_200"
        ,ROUND(((100*(CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_count" ELSE 0 END))::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_25" ELSE NULL END AS "JJA_25"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_50" ELSE NULL END AS "JJA_50"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_84" ELSE NULL END AS "JJA_84"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_200" ELSE NULL END AS "JJA_200"
        ,ROUND(((100*(CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_count" ELSE 0 END))::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_25" ELSE NULL END AS "JAS_25"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_50" ELSE NULL END AS "JAS_50"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_84" ELSE NULL END AS "JAS_84"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_200" ELSE NULL END AS "JAS_200"
        ,ROUND(((100*(CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_count" ELSE 0 END))::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_25" ELSE NULL END AS "ASO_25"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_50" ELSE NULL END AS "ASO_50"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_84" ELSE NULL END AS "ASO_84"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_200" ELSE NULL END AS "ASO_200"
        ,ROUND(((100*(CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_count" ELSE 0 END))::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_25" ELSE NULL END AS "SON_25"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_50" ELSE NULL END AS "SON_50"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_84" ELSE NULL END AS "SON_84"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_200" ELSE NULL END AS "SON_200"
        ,ROUND(((100*(CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_count" ELSE 0 END))::numeric/"SON_total"::numeric),2) AS "SON (% of days)"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_25" ELSE NULL END AS "OND_25"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_50" ELSE NULL END AS "OND_50"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_84" ELSE NULL END AS "OND_84"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_200" ELSE NULL END AS "OND_200"
        ,ROUND(((100*(CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_count" ELSE 0 END))::numeric/"OND_total"::numeric),2) AS "OND (% of days)"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_25" ELSE NULL END AS "NDJ_25"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_50" ELSE NULL END AS "NDJ_50"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_84" ELSE NULL END AS "NDJ_84"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_200" ELSE NULL END AS "NDJ_200"
        ,ROUND(((100*(CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_count" ELSE 0 END))::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_25" ELSE NULL END AS "DRY_25"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_50" ELSE NULL END AS "DRY_50"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_84" ELSE NULL END AS "DRY_84"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_200" ELSE NULL END AS "DRY_200"
        ,ROUND(((100*(CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_count" ELSE 0 END))::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_25" ELSE NULL END AS "WET_25"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_50" ELSE NULL END AS "WET_50"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_84" ELSE NULL END AS "WET_84"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_200" ELSE NULL END AS "WET_200"
        ,ROUND(((100*(CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_count" ELSE 0 END))::numeric/"WET_total"::numeric),2) AS "WET (% of days)"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_25" ELSE NULL END AS "ANNUAL_25"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_50" ELSE NULL END AS "ANNUAL_50"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_84" ELSE NULL END AS "ANNUAL_84"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_200" ELSE NULL END AS "ANNUAL_200"
        ,ROUND(((100*(CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_count" ELSE 0 END))::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_25" ELSE NULL END AS "DJFM_25"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_50" ELSE NULL END AS "DJFM_50"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_84" ELSE NULL END AS "DJFM_84"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_200" ELSE NULL END AS "DJFM_200"
        ,ROUND(((100*(CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_count" ELSE 0 END))::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"
    FROM aggreated_data ad
    LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
)
SELECT
    station
    ,'Flood and Excess Rainfall' AS product
    ,year
    ,CASE
        WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN
            "JFM_25"||'/'||"JFM_50"||'/'||"JFM_84"||'/'||"JFM_200"
        ELSE NULL
    END AS "JFM (25/50/84/200)"
    ,"JFM (% of days)" 
    ,CASE
        WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN
            "FMA_25"||'/'||"FMA_50"||'/'||"FMA_84"||'/'||"FMA_200"
        ELSE NULL
    END AS "FMA (25/50/84/200)"
    ,"FMA (% of days)"
    ,CASE
        WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN
            "MAM_25"||'/'||"MAM_50"||'/'||"MAM_84"||'/'||"MAM_200"
        ELSE NULL
    END AS "MAM (25/50/84/200)"
    ,"MAM (% of days)"
    ,CASE
        WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN
            "AMJ_25"||'/'||"AMJ_50"||'/'||"AMJ_84"||'/'||"AMJ_200"
        ELSE NULL
    END AS "AMJ (25/50/84/200)"
    ,"AMJ (% of days)"
    ,CASE
        WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN
            "MJJ_25"||'/'||"MJJ_50"||'/'||"MJJ_84"||'/'||"MJJ_200"
        ELSE NULL
    END AS "MJJ (25/50/84/200)"
    ,"MJJ (% of days)"
    ,CASE
        WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN
            "JJA_25"||'/'||"JJA_50"||'/'||"JJA_84"||'/'||"JJA_200"
        ELSE NULL
    END AS "JJA (25/50/84/200)"
    ,"JJA (% of days)"
    ,CASE
        WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN
            "JAS_25"||'/'||"JAS_50"||'/'||"JAS_84"||'/'||"JAS_200"
        ELSE NULL
    END AS "JAS (25/50/84/200)"
    ,"JAS (% of days)"
    ,CASE
        WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN
            "ASO_25"||'/'||"ASO_50"||'/'||"ASO_84"||'/'||"ASO_200"
        ELSE NULL
    END AS "ASO (25/50/84/200)"
    ,"ASO (% of days)"
    ,CASE
        WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN
            "SON_25"||'/'||"SON_50"||'/'||"SON_84"||'/'||"SON_200"
        ELSE NULL
    END AS "SON (25/50/84/200)"
    ,"SON (% of days)"
    ,CASE
        WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN
            "OND_25"||'/'||"OND_50"||'/'||"OND_84"||'/'||"OND_200"
        ELSE NULL
    END AS "OND (25/50/84/200)"
    ,"OND (% of days)"
    ,CASE
        WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN
            "NDJ_25"||'/'||"NDJ_50"||'/'||"NDJ_84"||'/'||"NDJ_200"
        ELSE NULL
    END AS "NDJ (25/50/84/200)"
    ,"NDJ (% of days)"
    ,CASE
        WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN
            "DRY_25"||'/'||"DRY_50"||'/'||"DRY_84"||'/'||"DRY_200"
        ELSE NULL
    END AS "DRY (25/50/84/200)"
    ,"DRY (% of days)"
    ,CASE
        WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN
            "WET_25"||'/'||"WET_50"||'/'||"WET_84"||'/'||"WET_200"
        ELSE NULL
    END AS "WET (25/50/84/200)"
    ,"WET (% of days)"
    ,CASE
        WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN
            "ANNUAL_25"||'/'||"ANNUAL_50"||'/'||"ANNUAL_84"||'/'||"ANNUAL_200"
        ELSE NULL
    END AS "ANNUAL (25/50/84/200)"
    ,"ANNUAL (% of days)"
    ,CASE
        WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN
            "DJFM_25"||'/'||"DJFM_50"||'/'||"DJFM_84"||'/'||"DJFM_200"
        ELSE NULL
    END AS "DJFM (25/50/84/200)"
    ,"DJFM (% of days)"
FROM aggregation_pct
ORDER BY year