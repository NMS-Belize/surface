WITH RECURSIVE month_days AS (
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
        ,CASE WHEN avg_value > {{threshold}} THEN 1 ELSE 0 END AS is_humidity_day
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol = 'RH'
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
        ,is_humidity_day
    FROM daily_data
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM daily_data
)
,daily_lagged AS (
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
        ,day - LAG(day) OVER (PARTITION BY station_id, year ORDER BY day) AS day_diff
    FROM daily_data  
    WHERE year BETWEEN 2021 AND 2025
)
,numbered_humidity_days AS ( 
    SELECT
        *
        ,CASE WHEN is_jfm THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_jfm ORDER BY day) ELSE NULL END AS "JFM_rn"
        ,CASE WHEN is_fma THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_fma ORDER BY day) ELSE NULL END AS "FMA_rn"
        ,CASE WHEN is_mam THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_mam ORDER BY day) ELSE NULL END AS "MAM_rn"
        ,CASE WHEN is_amj THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_amj ORDER BY day) ELSE NULL END AS "AMJ_rn"
        ,CASE WHEN is_mjj THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_mjj ORDER BY day) ELSE NULL END AS "MJJ_rn"
        ,CASE WHEN is_jja THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_jja ORDER BY day) ELSE NULL END AS "JJA_rn"
        ,CASE WHEN is_jas THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_jas ORDER BY day) ELSE NULL END AS "JAS_rn"
        ,CASE WHEN is_aso THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_aso ORDER BY day) ELSE NULL END AS "ASO_rn"
        ,CASE WHEN is_son THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_son ORDER BY day) ELSE NULL END AS "SON_rn"
        ,CASE WHEN is_ond THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_ond ORDER BY day) ELSE NULL END AS "OND_rn"
        ,CASE WHEN is_ndj THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_ndj ORDER BY day) ELSE NULL END AS "NDJ_rn"
        ,CASE WHEN is_dry THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_dry ORDER BY day) ELSE NULL END AS "DRY_rn"
        ,CASE WHEN is_wet THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_wet ORDER BY day) ELSE NULL END AS "WET_rn"
        ,CASE WHEN is_annual THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_annual ORDER BY day) ELSE NULL END AS "ANNUAL_rn"
        ,CASE WHEN is_djfm THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, is_djfm ORDER BY day) ELSE NULL END AS "DJFM_rn"
    FROM daily_lagged
)
,grouped_humidity_days AS (
    SELECT
        *
        ,SUM(CASE WHEN (is_jfm AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_jfm
            ORDER BY "JFM_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "JFM_group_id"
        ,SUM(CASE WHEN (is_fma AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_fma
            ORDER BY "FMA_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "FMA_group_id"
        ,SUM(CASE WHEN (is_mam AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_mam
            ORDER BY "MAM_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "MAM_group_id"
        ,SUM(CASE WHEN (is_amj AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_amj
            ORDER BY "AMJ_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "AMJ_group_id"
        ,SUM(CASE WHEN (is_mjj AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_mjj
            ORDER BY "MJJ_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "MJJ_group_id"
        ,SUM(CASE WHEN (is_jja AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_jja
            ORDER BY "JJA_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "JJA_group_id"
        ,SUM(CASE WHEN (is_jas AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_jas
            ORDER BY "JAS_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "JAS_group_id"
        ,SUM(CASE WHEN (is_aso AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_aso
            ORDER BY "ASO_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "ASO_group_id"
        ,SUM(CASE WHEN (is_son AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_son
            ORDER BY "SON_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "SON_group_id"
        ,SUM(CASE WHEN (is_ond AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_ond
            ORDER BY "OND_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "OND_group_id"
        ,SUM(CASE WHEN (is_ndj AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_ndj
            ORDER BY "NDJ_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "NDJ_group_id"
        ,SUM(CASE WHEN (is_dry AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_dry
            ORDER BY "DRY_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "DRY_group_id"
        ,SUM(CASE WHEN (is_wet AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_wet
            ORDER BY "WET_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "WET_group_id"
        ,SUM(CASE WHEN (is_annual AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_annual
            ORDER BY "ANNUAL_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "ANNUAL_group_id"
        ,SUM(CASE WHEN (is_djfm AND is_humidity_day = 0 OR day_diff > 1) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, is_djfm
            ORDER BY "DJFM_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "DJFM_group_id"
    FROM numbered_humidity_days
)
,consecutive_humidity_days AS (
    SELECT 
        *
        ,CASE WHEN is_jfm THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "JFM_group_id" ORDER BY "JFM_rn") ELSE NULL END AS "JFM_seq"
        ,CASE WHEN is_fma THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "FMA_group_id" ORDER BY "FMA_rn") ELSE NULL END AS "FMA_seq"
        ,CASE WHEN is_mam THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "MAM_group_id" ORDER BY "MAM_rn") ELSE NULL END AS "MAM_seq"
        ,CASE WHEN is_amj THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "AMJ_group_id" ORDER BY "AMJ_rn") ELSE NULL END AS "AMJ_seq"
        ,CASE WHEN is_mjj THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "MJJ_group_id" ORDER BY "MJJ_rn") ELSE NULL END AS "MJJ_seq"
        ,CASE WHEN is_jja THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "JJA_group_id" ORDER BY "JJA_rn") ELSE NULL END AS "JJA_seq"
        ,CASE WHEN is_jas THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "JAS_group_id" ORDER BY "JAS_rn") ELSE NULL END AS "JAS_seq"
        ,CASE WHEN is_aso THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "ASO_group_id" ORDER BY "ASO_rn") ELSE NULL END AS "ASO_seq"
        ,CASE WHEN is_son THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "SON_group_id" ORDER BY "SON_rn") ELSE NULL END AS "SON_seq"
        ,CASE WHEN is_ond THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "OND_group_id" ORDER BY "OND_rn") ELSE NULL END AS "OND_seq"
        ,CASE WHEN is_ndj THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "NDJ_group_id" ORDER BY "NDJ_rn") ELSE NULL END AS "NDJ_seq"
        ,CASE WHEN is_dry THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "DRY_group_id" ORDER BY "DRY_rn") ELSE NULL END AS "DRY_seq"
        ,CASE WHEN is_wet THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "WET_group_id" ORDER BY "WET_rn") ELSE NULL END AS "WET_seq"
        ,CASE WHEN is_annual THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "ANNUAL_group_id" ORDER BY "ANNUAL_rn") ELSE NULL END AS "ANNUAL_seq"
        ,CASE WHEN is_djfm THEN ROW_NUMBER() OVER (PARTITION BY station_id, year, "DJFM_group_id" ORDER BY "DJFM_rn") ELSE NULL END AS "DJFM_seq"
    FROM grouped_humidity_days
)
,fixed_consecutive_humidity_days AS (
    SELECT 
        station_id
        ,year
        ,month
        ,day
        ,is_humidity_day AS is_hd
        ,day_diff
        ,is_jfm
        ,is_fma
        ,is_mam
        ,is_amj
        ,is_mjj
        ,is_jja
        ,is_jas
        ,is_aso
        ,is_son
        ,is_ond
        ,is_ndj
        ,is_dry
        ,is_wet
        ,is_annual
        ,is_djfm        
        ,CASE WHEN "JFM_group_id" > 0 THEN "JFM_seq"-1 ELSE "JFM_seq" END AS "JFM_seq"
        ,CASE WHEN "FMA_group_id" > 0 THEN "FMA_seq"-1 ELSE "FMA_seq" END AS "FMA_seq"
        ,CASE WHEN "MAM_group_id" > 0 THEN "MAM_seq"-1 ELSE "MAM_seq" END AS "MAM_seq"
        ,CASE WHEN "AMJ_group_id" > 0 THEN "AMJ_seq"-1 ELSE "AMJ_seq" END AS "AMJ_seq"
        ,CASE WHEN "MJJ_group_id" > 0 THEN "MJJ_seq"-1 ELSE "MJJ_seq" END AS "MJJ_seq"
        ,CASE WHEN "JJA_group_id" > 0 THEN "JJA_seq"-1 ELSE "JJA_seq" END AS "JJA_seq"
        ,CASE WHEN "JAS_group_id" > 0 THEN "JAS_seq"-1 ELSE "JAS_seq" END AS "JAS_seq"
        ,CASE WHEN "ASO_group_id" > 0 THEN "ASO_seq"-1 ELSE "ASO_seq" END AS "ASO_seq"
        ,CASE WHEN "SON_group_id" > 0 THEN "SON_seq"-1 ELSE "SON_seq" END AS "SON_seq"
        ,CASE WHEN "OND_group_id" > 0 THEN "OND_seq"-1 ELSE "OND_seq" END AS "OND_seq"
        ,CASE WHEN "NDJ_group_id" > 0 THEN "NDJ_seq"-1 ELSE "NDJ_seq" END AS "NDJ_seq"
        ,CASE WHEN "DRY_group_id" > 0 THEN "DRY_seq"-1 ELSE "DRY_seq" END AS "DRY_seq"
        ,CASE WHEN "WET_group_id" > 0 THEN "WET_seq"-1 ELSE "WET_seq" END AS "WET_seq"
        ,CASE WHEN "ANNUAL_group_id" > 0 THEN "ANNUAL_seq"-1 ELSE "ANNUAL_seq" END AS "ANNUAL_seq"
        ,CASE WHEN "DJFM_group_id" > 0 THEN "DJFM_seq"-1 ELSE "DJFM_seq" END AS "DJFM_seq"
    FROM consecutive_humidity_days
)
,aggreated_data AS (
    SELECT
        st.name AS station
        ,year
        ,MAX(COALESCE("JFM_seq", 0)) AS "JFM"
        ,COUNT(DISTINCT CASE WHEN ((is_jfm) AND (day IS NOT NULL)) THEN day END) AS "JFM_count"
        ,MAX(CASE
                WHEN ((is_jfm) AND NOT (month = 1 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "JFM_max_day_diff"
        ,MAX(COALESCE("FMA_seq", 0)) AS "FMA"
        ,COUNT(DISTINCT CASE WHEN ((is_fma) AND (day IS NOT NULL)) THEN day END) AS "FMA_count"
        ,MAX(CASE
                WHEN ((is_fma) AND NOT (month = 2 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "FMA_max_day_diff"
        ,MAX(COALESCE("MAM_seq", 0)) AS "MAM"
        ,COUNT(DISTINCT CASE WHEN ((is_mam) AND (day IS NOT NULL)) THEN day END) AS "MAM_count"
        ,MAX(CASE
                WHEN ((is_mam) AND NOT (month = 3 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "MAM_max_day_diff"
        ,MAX(COALESCE("AMJ_seq", 0)) AS "AMJ"
        ,COUNT(DISTINCT CASE WHEN ((is_amj) AND (day IS NOT NULL)) THEN day END) AS "AMJ_count"
        ,MAX(CASE
                WHEN ((is_amj) AND NOT (month = 4 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "AMJ_max_day_diff"
        ,MAX(COALESCE("MJJ_seq", 0)) AS "MJJ"
        ,COUNT(DISTINCT CASE WHEN ((is_mjj) AND (day IS NOT NULL)) THEN day END) AS "MJJ_count"
        ,MAX(CASE
                WHEN ((is_mjj) AND NOT (month = 5 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "MJJ_max_day_diff"
        ,MAX(COALESCE("JJA_seq", 0)) AS "JJA"
        ,COUNT(DISTINCT CASE WHEN ((is_jja) AND (day IS NOT NULL)) THEN day END) AS "JJA_count"
        ,MAX(CASE
                WHEN ((is_jja) AND NOT (month = 6 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "JJA_max_day_diff"
        ,MAX(COALESCE("JAS_seq", 0)) AS "JAS"
        ,COUNT(DISTINCT CASE WHEN ((is_jas) AND (day IS NOT NULL)) THEN day END) AS "JAS_count"
        ,MAX(CASE
                WHEN ((is_jas) AND NOT (month = 7 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "JAS_max_day_diff"
        ,MAX(COALESCE("ASO_seq", 0)) AS "ASO"
        ,COUNT(DISTINCT CASE WHEN ((is_aso) AND (day IS NOT NULL)) THEN day END) AS "ASO_count"
        ,MAX(CASE
                WHEN ((is_aso) AND NOT (month = 8 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "ASO_max_day_diff"
        ,MAX(COALESCE("SON_seq", 0)) AS "SON"
        ,COUNT(DISTINCT CASE WHEN ((is_son) AND (day IS NOT NULL)) THEN day END) AS "SON_count"
        ,MAX(CASE
                WHEN ((is_son) AND NOT (month = 9 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "SON_max_day_diff"
        ,MAX(COALESCE("OND_seq", 0)) AS "OND"
        ,COUNT(DISTINCT CASE WHEN ((is_ond) AND (day IS NOT NULL)) THEN day END) AS "OND_count"
        ,MAX(CASE
                WHEN ((is_ond) AND NOT (month = 10 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "OND_max_day_diff"
        ,MAX(COALESCE("NDJ_seq", 0)) AS "NDJ"
        ,COUNT(DISTINCT CASE WHEN ((is_ndj) AND (day IS NOT NULL)) THEN day END) AS "NDJ_count"
        ,MAX(CASE
                WHEN ((is_ndj) AND NOT (month = 11 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "NDJ_max_day_diff"
        ,MAX(COALESCE("DRY_seq", 0)) AS "DRY"
        ,COUNT(DISTINCT CASE WHEN ((is_dry) AND (day IS NOT NULL)) THEN day END) AS "DRY_count"
        ,MAX(CASE
                WHEN ((is_dry) AND NOT (month = 0 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "DRY_max_day_diff"
        ,MAX(COALESCE("WET_seq", 0)) AS "WET"
        ,COUNT(DISTINCT CASE WHEN ((is_wet) AND (day IS NOT NULL)) THEN day END) AS "WET_count"
        ,MAX(CASE
                WHEN ((is_wet) AND NOT (month = 6 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "WET_max_day_diff"
        ,MAX(COALESCE("ANNUAL_seq", 0)) "ANNUAL"
        ,COUNT(DISTINCT CASE WHEN ((is_annual) AND (day IS NOT NULL)) THEN day END) AS "ANNUAL_count"
        ,MAX(CASE
                WHEN ((is_annual) AND NOT (month = 1 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "ANNUAL_max_day_diff"
        ,MAX(COALESCE("DJFM_seq", 0))AS "DJFM"
        ,COUNT(DISTINCT CASE WHEN ((is_djfm) AND (day IS NOT NULL)) THEN day END) AS "DJFM_count"
        ,MAX(CASE
                WHEN ((is_djfm) AND NOT (month = 0 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "DJFM_max_day_diff"
    FROM fixed_consecutive_humidity_days fchd
    JOIN wx_station st ON st.id = fchd.station_id
    GROUP BY st.name, year
)
,aggregation_pct AS (
    SELECT
        station
        ,ad.year
        ,CASE WHEN "JFM_max_day_diff" <= ({{max_day_gap}}+1) THEN "JFM" ELSE NULL END AS "JFM"
        ,ROUND(((100*(CASE WHEN "JFM_max_day_diff" <= ({{max_day_gap}}+1) THEN "JFM_count" ELSE 0 END))::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
        ,CASE WHEN "FMA_max_day_diff" <= ({{max_day_gap}}+1) THEN "FMA" ELSE NULL END AS "FMA"
        ,ROUND(((100*(CASE WHEN "FMA_max_day_diff" <= ({{max_day_gap}}+1) THEN "FMA_count" ELSE 0 END))::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"
        ,CASE WHEN "MAM_max_day_diff" <= ({{max_day_gap}}+1) THEN "MAM" ELSE NULL END AS "MAM"
        ,ROUND(((100*(CASE WHEN "MAM_max_day_diff" <= ({{max_day_gap}}+1) THEN "MAM_count" ELSE 0 END))::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"
        ,CASE WHEN "AMJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "AMJ" ELSE NULL END AS "AMJ"
        ,ROUND(((100*(CASE WHEN "AMJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "AMJ_count" ELSE 0 END))::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"
        ,CASE WHEN "MJJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "MJJ" ELSE NULL END AS "MJJ"
        ,ROUND(((100*(CASE WHEN "MJJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "MJJ_count" ELSE 0 END))::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"
        ,CASE WHEN "JJA_max_day_diff" <= ({{max_day_gap}}+1) THEN "JJA" ELSE NULL END AS "JJA"
        ,ROUND(((100*(CASE WHEN "JJA_max_day_diff" <= ({{max_day_gap}}+1) THEN "JJA_count" ELSE 0 END))::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"
        ,CASE WHEN "JAS_max_day_diff" <= ({{max_day_gap}}+1) THEN "JAS" ELSE NULL END AS "JAS"
        ,ROUND(((100*(CASE WHEN "JAS_max_day_diff" <= ({{max_day_gap}}+1) THEN "JAS_count" ELSE 0 END))::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"
        ,CASE WHEN "ASO_max_day_diff" <= ({{max_day_gap}}+1) THEN "ASO" ELSE NULL END AS "ASO"
        ,ROUND(((100*(CASE WHEN "ASO_max_day_diff" <= ({{max_day_gap}}+1) THEN "ASO_count" ELSE 0 END))::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"
        ,CASE WHEN "SON_max_day_diff" <= ({{max_day_gap}}+1) THEN "SON" ELSE NULL END AS "SON"
        ,ROUND(((100*(CASE WHEN "SON_max_day_diff" <= ({{max_day_gap}}+1) THEN "SON_count" ELSE 0 END))::numeric/"SON_total"::numeric),2) AS "SON (% of days)"
        ,CASE WHEN "OND_max_day_diff" <= ({{max_day_gap}}+1) THEN "OND" ELSE NULL END AS "OND"
        ,ROUND(((100*(CASE WHEN "OND_max_day_diff" <= ({{max_day_gap}}+1) THEN "OND_count" ELSE 0 END))::numeric/"OND_total"::numeric),2) AS "OND (% of days)"
        ,CASE WHEN "NDJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "NDJ" ELSE NULL END AS "NDJ"
        ,ROUND(((100*(CASE WHEN "NDJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "NDJ_count" ELSE 0 END))::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"
        ,CASE WHEN "DRY_max_day_diff" <= ({{max_day_gap}}+1) THEN "DRY" ELSE NULL END AS "DRY"
        ,ROUND(((100*(CASE WHEN "DRY_max_day_diff" <= ({{max_day_gap}}+1) THEN "DRY_count" ELSE 0 END))::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"
        ,CASE WHEN "WET_max_day_diff" <= ({{max_day_gap}}+1) THEN "WET" ELSE NULL END AS "WET"
        ,ROUND(((100*(CASE WHEN "WET_max_day_diff" <= ({{max_day_gap}}+1) THEN "WET_count" ELSE 0 END))::numeric/"WET_total"::numeric),2) AS "WET (% of days)"
        ,CASE WHEN "ANNUAL_max_day_diff" <= ({{max_day_gap}}+1) THEN "ANNUAL" ELSE NULL END AS "ANNUAL"
        ,ROUND(((100*(CASE WHEN "ANNUAL_max_day_diff" <= ({{max_day_gap}}+1) THEN "ANNUAL_count" ELSE 0 END))::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"
        ,CASE WHEN "DJFM_max_day_diff" <= ({{max_day_gap}}+1) THEN "DJFM" ELSE NULL END AS "DJFM"
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