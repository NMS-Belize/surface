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
        ,vr.symbol AS product
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,CASE 
            WHEN (avg_value BETWEEN 337.5 AND 360) OR (avg_value BETWEEN 0 AND 22.5) THEN 'N'
            WHEN avg_value BETWEEN 22.5 AND 67.5 THEN 'NE'
            WHEN avg_value BETWEEN 67.5 AND 112.5 THEN 'E'
            WHEN avg_value BETWEEN 112.5 AND 157.5 THEN 'SE'
            WHEN avg_value BETWEEN 157.5 AND 202.5 THEN 'S'
            WHEN avg_value BETWEEN 202.5 AND 247.5 THEN 'SW'
            WHEN avg_value BETWEEN 247.5 AND 292.5 THEN 'W'
            WHEN avg_value BETWEEN 292.5 AND 337.5 THEN 'NW'
        END AS value
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol = 'WNDDIR'
      AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
)
,extended_data AS(
    SELECT
        station_id
        ,product
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
        ,day - 1 - LAG(day) OVER (PARTITION BY station_id, product, year ORDER BY day) AS day_gap
    FROM extended_data
    WHERE year BETWEEN {{start_year}} AND {{end_year}}  
)
,aggreated_data AS (
    SELECT
        st.name AS station
        ,product
        ,year
        ,COUNT(CASE WHEN (is_jfm AND value = 'N') THEN 1 END) AS "JFM_N"
        ,COUNT(CASE WHEN (is_jfm AND value = 'NE') THEN 1 END) AS "JFM_NE"
        ,COUNT(CASE WHEN (is_jfm AND value = 'E') THEN 1 END) AS "JFM_E"
        ,COUNT(CASE WHEN (is_jfm AND value = 'SE') THEN 1 END) AS "JFM_SE"
        ,COUNT(CASE WHEN (is_jfm AND value = 'S') THEN 1 END) AS "JFM_S"
        ,COUNT(CASE WHEN (is_jfm AND value = 'SW') THEN 1 END) AS "JFM_SW"
        ,COUNT(CASE WHEN (is_jfm AND value = 'W') THEN 1 END) AS "JFM_W"
        ,COUNT(CASE WHEN (is_jfm AND value = 'NW') THEN 1 END) AS "JFM_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_jfm) AND (day IS NOT NULL)) THEN day END) AS "JFM_count"
        ,MAX(CASE WHEN ((is_jfm) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JFM_max_day_gap"
        ,COUNT(CASE WHEN (is_fma AND value = 'N') THEN 1 END) AS "FMA_N"
        ,COUNT(CASE WHEN (is_fma AND value = 'NE') THEN 1 END) AS "FMA_NE"
        ,COUNT(CASE WHEN (is_fma AND value = 'E') THEN 1 END) AS "FMA_E"
        ,COUNT(CASE WHEN (is_fma AND value = 'SE') THEN 1 END) AS "FMA_SE"
        ,COUNT(CASE WHEN (is_fma AND value = 'S') THEN 1 END) AS "FMA_S"
        ,COUNT(CASE WHEN (is_fma AND value = 'SW') THEN 1 END) AS "FMA_SW"
        ,COUNT(CASE WHEN (is_fma AND value = 'W') THEN 1 END) AS "FMA_W"
        ,COUNT(CASE WHEN (is_fma AND value = 'NW') THEN 1 END) AS "FMA_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_fma) AND (day IS NOT NULL)) THEN day END) AS "FMA_count"
        ,MAX(CASE WHEN ((is_fma) AND NOT (month = 2 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "FMA_max_day_gap"
        ,COUNT(CASE WHEN (is_mam AND value = 'N') THEN 1 END) AS "MAM_N"
        ,COUNT(CASE WHEN (is_mam AND value = 'NE') THEN 1 END) AS "MAM_NE"
        ,COUNT(CASE WHEN (is_mam AND value = 'E') THEN 1 END) AS "MAM_E"
        ,COUNT(CASE WHEN (is_mam AND value = 'SE') THEN 1 END) AS "MAM_SE"
        ,COUNT(CASE WHEN (is_mam AND value = 'S') THEN 1 END) AS "MAM_S"
        ,COUNT(CASE WHEN (is_mam AND value = 'SW') THEN 1 END) AS "MAM_SW"
        ,COUNT(CASE WHEN (is_mam AND value = 'W') THEN 1 END) AS "MAM_W"
        ,COUNT(CASE WHEN (is_mam AND value = 'NW') THEN 1 END) AS "MAM_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_mam) AND (day IS NOT NULL)) THEN day END) AS "MAM_count"
        ,MAX(CASE WHEN ((is_mam) AND NOT (month = 3 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MAM_max_day_gap"
        ,COUNT(CASE WHEN (is_amj AND value = 'N') THEN 1 END) AS "AMJ_N"
        ,COUNT(CASE WHEN (is_amj AND value = 'NE') THEN 1 END) AS "AMJ_NE"
        ,COUNT(CASE WHEN (is_amj AND value = 'E') THEN 1 END) AS "AMJ_E"
        ,COUNT(CASE WHEN (is_amj AND value = 'SE') THEN 1 END) AS "AMJ_SE"
        ,COUNT(CASE WHEN (is_amj AND value = 'S') THEN 1 END) AS "AMJ_S"
        ,COUNT(CASE WHEN (is_amj AND value = 'SW') THEN 1 END) AS "AMJ_SW"
        ,COUNT(CASE WHEN (is_amj AND value = 'W') THEN 1 END) AS "AMJ_W"
        ,COUNT(CASE WHEN (is_amj AND value = 'NW') THEN 1 END) AS "AMJ_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_amj) AND (day IS NOT NULL)) THEN day END) AS "AMJ_count"
        ,MAX(CASE WHEN ((is_amj) AND NOT (month = 4 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "AMJ_max_day_gap"
        ,COUNT(CASE WHEN (is_mjj AND value = 'N') THEN 1 END) AS "MJJ_N"
        ,COUNT(CASE WHEN (is_mjj AND value = 'NE') THEN 1 END) AS "MJJ_NE"
        ,COUNT(CASE WHEN (is_mjj AND value = 'E') THEN 1 END) AS "MJJ_E"
        ,COUNT(CASE WHEN (is_mjj AND value = 'SE') THEN 1 END) AS "MJJ_SE"
        ,COUNT(CASE WHEN (is_mjj AND value = 'S') THEN 1 END) AS "MJJ_S"
        ,COUNT(CASE WHEN (is_mjj AND value = 'SW') THEN 1 END) AS "MJJ_SW"
        ,COUNT(CASE WHEN (is_mjj AND value = 'W') THEN 1 END) AS "MJJ_W"
        ,COUNT(CASE WHEN (is_mjj AND value = 'NW') THEN 1 END) AS "MJJ_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_mjj) AND (day IS NOT NULL)) THEN day END) AS "MJJ_count"
        ,MAX(CASE WHEN ((is_mjj) AND NOT (month = 5 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MJJ_max_day_gap"
        ,COUNT(CASE WHEN (is_jja AND value = 'N') THEN 1 END) AS "JJA_N"
        ,COUNT(CASE WHEN (is_jja AND value = 'NE') THEN 1 END) AS "JJA_NE"
        ,COUNT(CASE WHEN (is_jja AND value = 'E') THEN 1 END) AS "JJA_E"
        ,COUNT(CASE WHEN (is_jja AND value = 'SE') THEN 1 END) AS "JJA_SE"
        ,COUNT(CASE WHEN (is_jja AND value = 'S') THEN 1 END) AS "JJA_S"
        ,COUNT(CASE WHEN (is_jja AND value = 'SW') THEN 1 END) AS "JJA_SW"
        ,COUNT(CASE WHEN (is_jja AND value = 'W') THEN 1 END) AS "JJA_W"
        ,COUNT(CASE WHEN (is_jja AND value = 'NW') THEN 1 END) AS "JJA_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_jja) AND (day IS NOT NULL)) THEN day END) AS "JJA_count"
        ,MAX(CASE WHEN ((is_jja) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JJA_max_day_gap"
        ,COUNT(CASE WHEN (is_jas AND value = 'N') THEN 1 END) AS "JAS_N"
        ,COUNT(CASE WHEN (is_jas AND value = 'NE') THEN 1 END) AS "JAS_NE"
        ,COUNT(CASE WHEN (is_jas AND value = 'E') THEN 1 END) AS "JAS_E"
        ,COUNT(CASE WHEN (is_jas AND value = 'SE') THEN 1 END) AS "JAS_SE"
        ,COUNT(CASE WHEN (is_jas AND value = 'S') THEN 1 END) AS "JAS_S"
        ,COUNT(CASE WHEN (is_jas AND value = 'SW') THEN 1 END) AS "JAS_SW"
        ,COUNT(CASE WHEN (is_jas AND value = 'W') THEN 1 END) AS "JAS_W"
        ,COUNT(CASE WHEN (is_jas AND value = 'NW') THEN 1 END) AS "JAS_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_jas) AND (day IS NOT NULL)) THEN day END) AS "JAS_count"
        ,MAX(CASE WHEN ((is_jas) AND NOT (month = 7 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JAS_max_day_gap"
        ,COUNT(CASE WHEN (is_aso AND value = 'N') THEN 1 END) AS "ASO_N"
        ,COUNT(CASE WHEN (is_aso AND value = 'NE') THEN 1 END) AS "ASO_NE"
        ,COUNT(CASE WHEN (is_aso AND value = 'E') THEN 1 END) AS "ASO_E"
        ,COUNT(CASE WHEN (is_aso AND value = 'SE') THEN 1 END) AS "ASO_SE"
        ,COUNT(CASE WHEN (is_aso AND value = 'S') THEN 1 END) AS "ASO_S"
        ,COUNT(CASE WHEN (is_aso AND value = 'SW') THEN 1 END) AS "ASO_SW"
        ,COUNT(CASE WHEN (is_aso AND value = 'W') THEN 1 END) AS "ASO_W"
        ,COUNT(CASE WHEN (is_aso AND value = 'NW') THEN 1 END) AS "ASO_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_aso) AND (day IS NOT NULL)) THEN day END) AS "ASO_count"
        ,MAX(CASE WHEN ((is_aso) AND NOT (month = 8 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ASO_max_day_gap"
        ,COUNT(CASE WHEN (is_son AND value = 'N') THEN 1 END) AS "SON_N"
        ,COUNT(CASE WHEN (is_son AND value = 'NE') THEN 1 END) AS "SON_NE"
        ,COUNT(CASE WHEN (is_son AND value = 'E') THEN 1 END) AS "SON_E"
        ,COUNT(CASE WHEN (is_son AND value = 'SE') THEN 1 END) AS "SON_SE"
        ,COUNT(CASE WHEN (is_son AND value = 'S') THEN 1 END) AS "SON_S"
        ,COUNT(CASE WHEN (is_son AND value = 'SW') THEN 1 END) AS "SON_SW"
        ,COUNT(CASE WHEN (is_son AND value = 'W') THEN 1 END) AS "SON_W"
        ,COUNT(CASE WHEN (is_son AND value = 'NW') THEN 1 END) AS "SON_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_son) AND (day IS NOT NULL)) THEN day END) AS "SON_count"
        ,MAX(CASE WHEN ((is_son) AND NOT (month = 9 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "SON_max_day_gap"
        ,COUNT(CASE WHEN (is_ond AND value = 'N') THEN 1 END) AS "OND_N"
        ,COUNT(CASE WHEN (is_ond AND value = 'NE') THEN 1 END) AS "OND_NE"
        ,COUNT(CASE WHEN (is_ond AND value = 'E') THEN 1 END) AS "OND_E"
        ,COUNT(CASE WHEN (is_ond AND value = 'SE') THEN 1 END) AS "OND_SE"
        ,COUNT(CASE WHEN (is_ond AND value = 'S') THEN 1 END) AS "OND_S"
        ,COUNT(CASE WHEN (is_ond AND value = 'SW') THEN 1 END) AS "OND_SW"
        ,COUNT(CASE WHEN (is_ond AND value = 'W') THEN 1 END) AS "OND_W"
        ,COUNT(CASE WHEN (is_ond AND value = 'NW') THEN 1 END) AS "OND_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_ond) AND (day IS NOT NULL)) THEN day END) AS "OND_count"
        ,MAX(CASE WHEN ((is_ond) AND NOT (month = 10 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "OND_max_day_gap"
        ,COUNT(CASE WHEN (is_ndj AND value = 'N') THEN 1 END) AS "NDJ_N"
        ,COUNT(CASE WHEN (is_ndj AND value = 'NE') THEN 1 END) AS "NDJ_NE"
        ,COUNT(CASE WHEN (is_ndj AND value = 'E') THEN 1 END) AS "NDJ_E"
        ,COUNT(CASE WHEN (is_ndj AND value = 'SE') THEN 1 END) AS "NDJ_SE"
        ,COUNT(CASE WHEN (is_ndj AND value = 'S') THEN 1 END) AS "NDJ_S"
        ,COUNT(CASE WHEN (is_ndj AND value = 'SW') THEN 1 END) AS "NDJ_SW"
        ,COUNT(CASE WHEN (is_ndj AND value = 'W') THEN 1 END) AS "NDJ_W"
        ,COUNT(CASE WHEN (is_ndj AND value = 'NW') THEN 1 END) AS "NDJ_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_ndj) AND (day IS NOT NULL)) THEN day END) AS "NDJ_count"
        ,MAX(CASE WHEN ((is_ndj) AND NOT (month = 11 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "NDJ_max_day_gap"
        ,COUNT(CASE WHEN (is_dry AND value = 'N') THEN 1 END) AS "DRY_N"
        ,COUNT(CASE WHEN (is_dry AND value = 'NE') THEN 1 END) AS "DRY_NE"
        ,COUNT(CASE WHEN (is_dry AND value = 'E') THEN 1 END) AS "DRY_E"
        ,COUNT(CASE WHEN (is_dry AND value = 'SE') THEN 1 END) AS "DRY_SE"
        ,COUNT(CASE WHEN (is_dry AND value = 'S') THEN 1 END) AS "DRY_S"
        ,COUNT(CASE WHEN (is_dry AND value = 'SW') THEN 1 END) AS "DRY_SW"
        ,COUNT(CASE WHEN (is_dry AND value = 'W') THEN 1 END) AS "DRY_W"
        ,COUNT(CASE WHEN (is_dry AND value = 'NW') THEN 1 END) AS "DRY_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_dry) AND (day IS NOT NULL)) THEN day END) AS "DRY_count"
        ,MAX(CASE WHEN ((is_dry) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "DRY_max_day_gap"
        ,COUNT(CASE WHEN (is_wet AND value = 'N') THEN 1 END) AS "WET_N"
        ,COUNT(CASE WHEN (is_wet AND value = 'NE') THEN 1 END) AS "WET_NE"
        ,COUNT(CASE WHEN (is_wet AND value = 'E') THEN 1 END) AS "WET_E"
        ,COUNT(CASE WHEN (is_wet AND value = 'SE') THEN 1 END) AS "WET_SE"
        ,COUNT(CASE WHEN (is_wet AND value = 'S') THEN 1 END) AS "WET_S"
        ,COUNT(CASE WHEN (is_wet AND value = 'SW') THEN 1 END) AS "WET_SW"
        ,COUNT(CASE WHEN (is_wet AND value = 'W') THEN 1 END) AS "WET_W"
        ,COUNT(CASE WHEN (is_wet AND value = 'NW') THEN 1 END) AS "WET_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_wet) AND (day IS NOT NULL)) THEN day END) AS "WET_count"
        ,MAX(CASE WHEN ((is_wet) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "WET_max_day_gap"
        ,COUNT(CASE WHEN (is_annual AND value = 'N') THEN 1 END) AS "ANNUAL_N"
        ,COUNT(CASE WHEN (is_annual AND value = 'NE') THEN 1 END) AS "ANNUAL_NE"
        ,COUNT(CASE WHEN (is_annual AND value = 'E') THEN 1 END) AS "ANNUAL_E"
        ,COUNT(CASE WHEN (is_annual AND value = 'SE') THEN 1 END) AS "ANNUAL_SE"
        ,COUNT(CASE WHEN (is_annual AND value = 'S') THEN 1 END) AS "ANNUAL_S"
        ,COUNT(CASE WHEN (is_annual AND value = 'SW') THEN 1 END) AS "ANNUAL_SW"
        ,COUNT(CASE WHEN (is_annual AND value = 'W') THEN 1 END) AS "ANNUAL_W"
        ,COUNT(CASE WHEN (is_annual AND value = 'NW') THEN 1 END) AS "ANNUAL_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_annual) AND (day IS NOT NULL)) THEN day END) AS "ANNUAL_count"
        ,MAX(CASE WHEN ((is_annual) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ANNUAL_max_day_gap"
        ,COUNT(CASE WHEN (is_djfm AND value = 'N') THEN 1 END) AS "DJFM_N"
        ,COUNT(CASE WHEN (is_djfm AND value = 'NE') THEN 1 END) AS "DJFM_NE"
        ,COUNT(CASE WHEN (is_djfm AND value = 'E') THEN 1 END) AS "DJFM_E"
        ,COUNT(CASE WHEN (is_djfm AND value = 'SE') THEN 1 END) AS "DJFM_SE"
        ,COUNT(CASE WHEN (is_djfm AND value = 'S') THEN 1 END) AS "DJFM_S"
        ,COUNT(CASE WHEN (is_djfm AND value = 'SW') THEN 1 END) AS "DJFM_SW"
        ,COUNT(CASE WHEN (is_djfm AND value = 'W') THEN 1 END) AS "DJFM_W"
        ,COUNT(CASE WHEN (is_djfm AND value = 'NW') THEN 1 END) AS "DJFM_NW"
        ,COUNT(DISTINCT CASE WHEN ((is_djfm) AND (day IS NOT NULL)) THEN day END) AS "DJFM_count"
        ,MAX(CASE WHEN ((is_djfm) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "DJFM_max_day_gap"
    FROM daily_lagged_data dld
    JOIN wx_station st ON st.id = dld.station_id
    GROUP BY st.name, product, year
)
,aggregation_pct AS (
    SELECT
        station
        ,product
        ,ad.year
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JFM_N"::numeric)/"JFM_count"::numeric,2) END AS "JFM_N"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JFM_NE"::numeric)/"JFM_count"::numeric,2) END AS "JFM_NE"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JFM_E"::numeric)/"JFM_count"::numeric,2) END AS "JFM_E"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JFM_SE"::numeric)/"JFM_count"::numeric,2) END AS "JFM_SE"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JFM_S"::numeric)/"JFM_count"::numeric,2) END AS "JFM_S"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JFM_SW"::numeric)/"JFM_count"::numeric,2) END AS "JFM_SW"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JFM_W"::numeric)/"JFM_count"::numeric,2) END AS "JFM_W"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JFM_NW"::numeric)/"JFM_count"::numeric,2) END AS "JFM_NW"
        ,ROUND(((100*(CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_count" ELSE 0 END))::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"FMA_N"::numeric)/"FMA_count"::numeric,2) END AS "FMA_N"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"FMA_NE"::numeric)/"FMA_count"::numeric,2) END AS "FMA_NE"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"FMA_E"::numeric)/"FMA_count"::numeric,2) END AS "FMA_E"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"FMA_SE"::numeric)/"FMA_count"::numeric,2) END AS "FMA_SE"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"FMA_S"::numeric)/"FMA_count"::numeric,2) END AS "FMA_S"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"FMA_SW"::numeric)/"FMA_count"::numeric,2) END AS "FMA_SW"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"FMA_W"::numeric)/"FMA_count"::numeric,2) END AS "FMA_W"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"FMA_NW"::numeric)/"FMA_count"::numeric,2) END AS "FMA_NW"
        ,ROUND(((100*(CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_count" ELSE 0 END))::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MAM_N"::numeric)/"MAM_count"::numeric,2) END AS "MAM_N"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MAM_NE"::numeric)/"MAM_count"::numeric,2) END AS "MAM_NE"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MAM_E"::numeric)/"MAM_count"::numeric,2) END AS "MAM_E"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MAM_SE"::numeric)/"MAM_count"::numeric,2) END AS "MAM_SE"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MAM_S"::numeric)/"MAM_count"::numeric,2) END AS "MAM_S"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MAM_SW"::numeric)/"MAM_count"::numeric,2) END AS "MAM_SW"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MAM_W"::numeric)/"MAM_count"::numeric,2) END AS "MAM_W"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MAM_NW"::numeric)/"MAM_count"::numeric,2) END AS "MAM_NW"
        ,ROUND(((100*(CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_count" ELSE 0 END))::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"AMJ_N"::numeric)/"AMJ_count"::numeric,2) END AS "AMJ_N"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"AMJ_NE"::numeric)/"AMJ_count"::numeric,2) END AS "AMJ_NE"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"AMJ_E"::numeric)/"AMJ_count"::numeric,2) END AS "AMJ_E"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"AMJ_SE"::numeric)/"AMJ_count"::numeric,2) END AS "AMJ_SE"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"AMJ_S"::numeric)/"AMJ_count"::numeric,2) END AS "AMJ_S"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"AMJ_SW"::numeric)/"AMJ_count"::numeric,2) END AS "AMJ_SW"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"AMJ_W"::numeric)/"AMJ_count"::numeric,2) END AS "AMJ_W"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"AMJ_NW"::numeric)/"AMJ_count"::numeric,2) END AS "AMJ_NW"
        ,ROUND(((100*(CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_count" ELSE 0 END))::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MJJ_N"::numeric)/"MJJ_count"::numeric,2) END AS "MJJ_N"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MJJ_NE"::numeric)/"MJJ_count"::numeric,2) END AS "MJJ_NE"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MJJ_E"::numeric)/"MJJ_count"::numeric,2) END AS "MJJ_E"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MJJ_SE"::numeric)/"MJJ_count"::numeric,2) END AS "MJJ_SE"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MJJ_S"::numeric)/"MJJ_count"::numeric,2) END AS "MJJ_S"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MJJ_SW"::numeric)/"MJJ_count"::numeric,2) END AS "MJJ_SW"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MJJ_W"::numeric)/"MJJ_count"::numeric,2) END AS "MJJ_W"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"MJJ_NW"::numeric)/"MJJ_count"::numeric,2) END AS "MJJ_NW"
        ,ROUND(((100*(CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_count" ELSE 0 END))::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JJA_N"::numeric)/"JJA_count"::numeric,2) END AS "JJA_N"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JJA_NE"::numeric)/"JJA_count"::numeric,2) END AS "JJA_NE"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JJA_E"::numeric)/"JJA_count"::numeric,2) END AS "JJA_E"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JJA_SE"::numeric)/"JJA_count"::numeric,2) END AS "JJA_SE"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JJA_S"::numeric)/"JJA_count"::numeric,2) END AS "JJA_S"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JJA_SW"::numeric)/"JJA_count"::numeric,2) END AS "JJA_SW"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JJA_W"::numeric)/"JJA_count"::numeric,2) END AS "JJA_W"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JJA_NW"::numeric)/"JJA_count"::numeric,2) END AS "JJA_NW"
        ,ROUND(((100*(CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_count" ELSE 0 END))::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JAS_N"::numeric)/"JAS_count"::numeric,2) END AS "JAS_N"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JAS_NE"::numeric)/"JAS_count"::numeric,2) END AS "JAS_NE"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JAS_E"::numeric)/"JAS_count"::numeric,2) END AS "JAS_E"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JAS_SE"::numeric)/"JAS_count"::numeric,2) END AS "JAS_SE"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JAS_S"::numeric)/"JAS_count"::numeric,2) END AS "JAS_S"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JAS_SW"::numeric)/"JAS_count"::numeric,2) END AS "JAS_SW"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JAS_W"::numeric)/"JAS_count"::numeric,2) END AS "JAS_W"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"JAS_NW"::numeric)/"JAS_count"::numeric,2) END AS "JAS_NW"
        ,ROUND(((100*(CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_count" ELSE 0 END))::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ASO_N"::numeric)/"ASO_count"::numeric,2) END AS "ASO_N"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ASO_NE"::numeric)/"ASO_count"::numeric,2) END AS "ASO_NE"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ASO_E"::numeric)/"ASO_count"::numeric,2) END AS "ASO_E"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ASO_SE"::numeric)/"ASO_count"::numeric,2) END AS "ASO_SE"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ASO_S"::numeric)/"ASO_count"::numeric,2) END AS "ASO_S"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ASO_SW"::numeric)/"ASO_count"::numeric,2) END AS "ASO_SW"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ASO_W"::numeric)/"ASO_count"::numeric,2) END AS "ASO_W"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ASO_NW"::numeric)/"ASO_count"::numeric,2) END AS "ASO_NW"
        ,ROUND(((100*(CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_count" ELSE 0 END))::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"SON_N"::numeric)/"SON_count"::numeric,2) END AS "SON_N"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"SON_NE"::numeric)/"SON_count"::numeric,2) END AS "SON_NE"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"SON_E"::numeric)/"SON_count"::numeric,2) END AS "SON_E"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"SON_SE"::numeric)/"SON_count"::numeric,2) END AS "SON_SE"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"SON_S"::numeric)/"SON_count"::numeric,2) END AS "SON_S"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"SON_SW"::numeric)/"SON_count"::numeric,2) END AS "SON_SW"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"SON_W"::numeric)/"SON_count"::numeric,2) END AS "SON_W"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"SON_NW"::numeric)/"SON_count"::numeric,2) END AS "SON_NW"
        ,ROUND(((100*(CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_count" ELSE 0 END))::numeric/"SON_total"::numeric),2) AS "SON (% of days)"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"OND_N"::numeric)/"OND_count"::numeric,2) END AS "OND_N"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"OND_NE"::numeric)/"OND_count"::numeric,2) END AS "OND_NE"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"OND_E"::numeric)/"OND_count"::numeric,2) END AS "OND_E"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"OND_SE"::numeric)/"OND_count"::numeric,2) END AS "OND_SE"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"OND_S"::numeric)/"OND_count"::numeric,2) END AS "OND_S"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"OND_SW"::numeric)/"OND_count"::numeric,2) END AS "OND_SW"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"OND_W"::numeric)/"OND_count"::numeric,2) END AS "OND_W"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"OND_NW"::numeric)/"OND_count"::numeric,2) END AS "OND_NW"
        ,ROUND(((100*(CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_count" ELSE 0 END))::numeric/"OND_total"::numeric),2) AS "OND (% of days)"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"NDJ_N"::numeric)/"NDJ_count"::numeric,2) END AS "NDJ_N"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"NDJ_NE"::numeric)/"NDJ_count"::numeric,2) END AS "NDJ_NE"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"NDJ_E"::numeric)/"NDJ_count"::numeric,2) END AS "NDJ_E"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"NDJ_SE"::numeric)/"NDJ_count"::numeric,2) END AS "NDJ_SE"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"NDJ_S"::numeric)/"NDJ_count"::numeric,2) END AS "NDJ_S"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"NDJ_SW"::numeric)/"NDJ_count"::numeric,2) END AS "NDJ_SW"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"NDJ_W"::numeric)/"NDJ_count"::numeric,2) END AS "NDJ_W"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"NDJ_NW"::numeric)/"NDJ_count"::numeric,2) END AS "NDJ_NW"
        ,ROUND(((100*(CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_count" ELSE 0 END))::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DRY_N"::numeric)/"DRY_count"::numeric,2) END AS "DRY_N"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DRY_NE"::numeric)/"DRY_count"::numeric,2) END AS "DRY_NE"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DRY_E"::numeric)/"DRY_count"::numeric,2) END AS "DRY_E"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DRY_SE"::numeric)/"DRY_count"::numeric,2) END AS "DRY_SE"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DRY_S"::numeric)/"DRY_count"::numeric,2) END AS "DRY_S"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DRY_SW"::numeric)/"DRY_count"::numeric,2) END AS "DRY_SW"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DRY_W"::numeric)/"DRY_count"::numeric,2) END AS "DRY_W"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DRY_NW"::numeric)/"DRY_count"::numeric,2) END AS "DRY_NW"
        ,ROUND(((100*(CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_count" ELSE 0 END))::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"WET_N"::numeric)/"WET_count"::numeric,2) END AS "WET_N"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"WET_NE"::numeric)/"WET_count"::numeric,2) END AS "WET_NE"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"WET_E"::numeric)/"WET_count"::numeric,2) END AS "WET_E"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"WET_SE"::numeric)/"WET_count"::numeric,2) END AS "WET_SE"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"WET_S"::numeric)/"WET_count"::numeric,2) END AS "WET_S"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"WET_SW"::numeric)/"WET_count"::numeric,2) END AS "WET_SW"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"WET_W"::numeric)/"WET_count"::numeric,2) END AS "WET_W"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"WET_NW"::numeric)/"WET_count"::numeric,2) END AS "WET_NW"
        ,ROUND(((100*(CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_count" ELSE 0 END))::numeric/"WET_total"::numeric),2) AS "WET (% of days)"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ANNUAL_N"::numeric)/"ANNUAL_count"::numeric,2) END AS "ANNUAL_N"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ANNUAL_NE"::numeric)/"ANNUAL_count"::numeric,2) END AS "ANNUAL_NE"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ANNUAL_E"::numeric)/"ANNUAL_count"::numeric,2) END AS "ANNUAL_E"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ANNUAL_SE"::numeric)/"ANNUAL_count"::numeric,2) END AS "ANNUAL_SE"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ANNUAL_S"::numeric)/"ANNUAL_count"::numeric,2) END AS "ANNUAL_S"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ANNUAL_SW"::numeric)/"ANNUAL_count"::numeric,2) END AS "ANNUAL_SW"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ANNUAL_W"::numeric)/"ANNUAL_count"::numeric,2) END AS "ANNUAL_W"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"ANNUAL_NW"::numeric)/"ANNUAL_count"::numeric,2) END AS "ANNUAL_NW"
        ,ROUND(((100*(CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_count" ELSE 0 END))::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DJFM_N"::numeric)/"DJFM_count"::numeric,2) END AS "DJFM_N"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DJFM_NE"::numeric)/"DJFM_count"::numeric,2) END AS "DJFM_NE"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DJFM_E"::numeric)/"DJFM_count"::numeric,2) END AS "DJFM_E"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DJFM_SE"::numeric)/"DJFM_count"::numeric,2) END AS "DJFM_SE"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DJFM_S"::numeric)/"DJFM_count"::numeric,2) END AS "DJFM_S"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DJFM_SW"::numeric)/"DJFM_count"::numeric,2) END AS "DJFM_SW"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DJFM_W"::numeric)/"DJFM_count"::numeric,2) END AS "DJFM_W"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN ROUND((100*"DJFM_NW"::numeric)/"DJFM_count"::numeric,2) END AS "DJFM_NW"
        ,ROUND(((100*(CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_count" ELSE 0 END))::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"
    FROM aggreated_data ad
    LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
)
SELECT
    station
    ,product
    ,year
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_N" ELSE NULL END AS "JFM_1"
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_NE" ELSE NULL END AS "JFM_2"
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_E" ELSE NULL END AS "JFM_3"
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_SE" ELSE NULL END AS "JFM_4"
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_S" ELSE NULL END AS "JFM_5"
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_SW" ELSE NULL END AS "JFM_6"
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_W" ELSE NULL END AS "JFM_7"
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_NW" ELSE NULL END AS "JFM_8"
    ,"JFM (% of days)" 
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_N" ELSE NULL END AS "FMA_1"
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_NE" ELSE NULL END AS "FMA_2"
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_E" ELSE NULL END AS "FMA_3"
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_SE" ELSE NULL END AS "FMA_4"
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_S" ELSE NULL END AS "FMA_5"
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_SW" ELSE NULL END AS "FMA_6"
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_W" ELSE NULL END AS "FMA_7"
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_NW" ELSE NULL END AS "FMA_8"
    ,"FMA (% of days)"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_N" ELSE NULL END AS "MAM_1"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_NE" ELSE NULL END AS "MAM_2"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_E" ELSE NULL END AS "MAM_3"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_SE" ELSE NULL END AS "MAM_4"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_S" ELSE NULL END AS "MAM_5"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_SW" ELSE NULL END AS "MAM_6"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_W" ELSE NULL END AS "MAM_7"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_NW" ELSE NULL END AS "MAM_8"
    ,"MAM (% of days)"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_N" ELSE NULL END AS "AMJ_1"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_NE" ELSE NULL END AS "AMJ_2"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_E" ELSE NULL END AS "AMJ_3"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_SE" ELSE NULL END AS "AMJ_4"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_S" ELSE NULL END AS "AMJ_5"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_SW" ELSE NULL END AS "AMJ_6"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_W" ELSE NULL END AS "AMJ_7"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_NW" ELSE NULL END AS "AMJ_8"
    ,"AMJ (% of days)"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_N" ELSE NULL END AS "MJJ_1"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_NE" ELSE NULL END AS "MJJ_2"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_E" ELSE NULL END AS "MJJ_3"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_SE" ELSE NULL END AS "MJJ_4"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_S" ELSE NULL END AS "MJJ_5"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_SW" ELSE NULL END AS "MJJ_6"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_W" ELSE NULL END AS "MJJ_7"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_NW" ELSE NULL END AS "MJJ_8"
    ,"MJJ (% of days)"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_N" ELSE NULL END AS "JJA_1"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_NE" ELSE NULL END AS "JJA_2"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_E" ELSE NULL END AS "JJA_3"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_SE" ELSE NULL END AS "JJA_4"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_S" ELSE NULL END AS "JJA_5"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_SW" ELSE NULL END AS "JJA_6"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_W" ELSE NULL END AS "JJA_7"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_NW" ELSE NULL END AS "JJA_8"
    ,"JJA (% of days)"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_N" ELSE NULL END AS "JAS_1"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_NE" ELSE NULL END AS "JAS_2"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_E" ELSE NULL END AS "JAS_3"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_SE" ELSE NULL END AS "JAS_4"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_S" ELSE NULL END AS "JAS_5"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_SW" ELSE NULL END AS "JAS_6"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_W" ELSE NULL END AS "JAS_7"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_NW" ELSE NULL END AS "JAS_8"
    ,"JAS (% of days)"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_N" ELSE NULL END AS "ASO_1"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_NE" ELSE NULL END AS "ASO_2"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_E" ELSE NULL END AS "ASO_3"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_SE" ELSE NULL END AS "ASO_4"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_S" ELSE NULL END AS "ASO_5"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_SW" ELSE NULL END AS "ASO_6"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_W" ELSE NULL END AS "ASO_7"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_NW" ELSE NULL END AS "ASO_8"
    ,"ASO (% of days)"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_N" ELSE NULL END AS "SON_1"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_NE" ELSE NULL END AS "SON_2"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_E" ELSE NULL END AS "SON_3"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_SE" ELSE NULL END AS "SON_4"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_S" ELSE NULL END AS "SON_5"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_SW" ELSE NULL END AS "SON_6"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_W" ELSE NULL END AS "SON_7"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_NW" ELSE NULL END AS "SON_8"
    ,"SON (% of days)"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_N" ELSE NULL END AS "OND_1"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_NE" ELSE NULL END AS "OND_2"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_E" ELSE NULL END AS "OND_3"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_SE" ELSE NULL END AS "OND_4"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_S" ELSE NULL END AS "OND_5"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_SW" ELSE NULL END AS "OND_6"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_W" ELSE NULL END AS "OND_7"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_NW" ELSE NULL END AS "OND_8"
    ,"OND (% of days)"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_N" ELSE NULL END AS "NDJ_1"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_NE" ELSE NULL END AS "NDJ_2"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_E" ELSE NULL END AS "NDJ_3"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_SE" ELSE NULL END AS "NDJ_4"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_S" ELSE NULL END AS "NDJ_5"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_SW" ELSE NULL END AS "NDJ_6"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_W" ELSE NULL END AS "NDJ_7"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_NW" ELSE NULL END AS "NDJ_8"
    ,"NDJ (% of days)"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_N" ELSE NULL END AS "DRY_1"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_NE" ELSE NULL END AS "DRY_2"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_E" ELSE NULL END AS "DRY_3"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_SE" ELSE NULL END AS "DRY_4"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_S" ELSE NULL END AS "DRY_5"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_SW" ELSE NULL END AS "DRY_6"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_W" ELSE NULL END AS "DRY_7"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_NW" ELSE NULL END AS "DRY_8"
    ,"DRY (% of days)"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_N" ELSE NULL END AS "WET_1"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_NE" ELSE NULL END AS "WET_2"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_E" ELSE NULL END AS "WET_3"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_SE" ELSE NULL END AS "WET_4"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_S" ELSE NULL END AS "WET_5"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_SW" ELSE NULL END AS "WET_6"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_W" ELSE NULL END AS "WET_7"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_NW" ELSE NULL END AS "WET_8"
    ,"WET (% of days)"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_N" ELSE NULL END AS "ANNUAL_1"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_NE" ELSE NULL END AS "ANNUAL_2"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_E" ELSE NULL END AS "ANNUAL_3"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_SE" ELSE NULL END AS "ANNUAL_4"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_S" ELSE NULL END AS "ANNUAL_5"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_SW" ELSE NULL END AS "ANNUAL_6"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_W" ELSE NULL END AS "ANNUAL_7"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_NW" ELSE NULL END AS "ANNUAL_8"
    ,"ANNUAL (% of days)"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_N" ELSE NULL END AS "DJFM_1"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_NE" ELSE NULL END AS "DJFM_2"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_E" ELSE NULL END AS "DJFM_3"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_SE" ELSE NULL END AS "DJFM_4"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_S" ELSE NULL END AS "DJFM_5"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_SW" ELSE NULL END AS "DJFM_6"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_W" ELSE NULL END AS "DJFM_7"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_NW" ELSE NULL END AS "DJFM_8"
    ,"DJFM (% of days)"
FROM aggregation_pct
ORDER BY year