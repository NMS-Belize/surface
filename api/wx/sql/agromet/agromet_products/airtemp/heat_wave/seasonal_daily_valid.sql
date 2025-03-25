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
        ,vr.symbol AS variable_symbol
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,min_value
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol IN ('TEMP', 'TEMPMIN', 'TEMPMAX')
      AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
)
,heat_wave_data AS (
    SELECT
        station_id
        ,variable_symbol
        ,day
        ,day_of_month
        ,month
        ,year
        ,CASE WHEN min_value > {{threshold}} THEN TRUE ELSE FALSE END AS is_heat_day
    FROM daily_data
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
        ,is_heat_day
    FROM heat_wave_data
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM heat_wave_data
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
,numbered_heat_days AS ( 
    SELECT
        *
        ,CASE WHEN is_jfm THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_jfm ORDER BY day) ELSE NULL END AS "JFM_rn"
        ,CASE WHEN is_fma THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_fma ORDER BY day) ELSE NULL END AS "FMA_rn"
        ,CASE WHEN is_mam THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_mam ORDER BY day) ELSE NULL END AS "MAM_rn"
        ,CASE WHEN is_amj THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_amj ORDER BY day) ELSE NULL END AS "AMJ_rn"
        ,CASE WHEN is_mjj THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_mjj ORDER BY day) ELSE NULL END AS "MJJ_rn"
        ,CASE WHEN is_jja THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_jja ORDER BY day) ELSE NULL END AS "JJA_rn"
        ,CASE WHEN is_jas THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_jas ORDER BY day) ELSE NULL END AS "JAS_rn"
        ,CASE WHEN is_aso THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_aso ORDER BY day) ELSE NULL END AS "ASO_rn"
        ,CASE WHEN is_son THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_son ORDER BY day) ELSE NULL END AS "SON_rn"
        ,CASE WHEN is_ond THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_ond ORDER BY day) ELSE NULL END AS "OND_rn"
        ,CASE WHEN is_ndj THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_ndj ORDER BY day) ELSE NULL END AS "NDJ_rn"
        ,CASE WHEN is_dry THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_dry ORDER BY day) ELSE NULL END AS "DRY_rn"
        ,CASE WHEN is_wet THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_wet ORDER BY day) ELSE NULL END AS "WET_rn"
        ,CASE WHEN is_annual THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_annual ORDER BY day) ELSE NULL END AS "ANNUAL_rn"
        ,CASE WHEN is_djfm THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, is_djfm ORDER BY day) ELSE NULL END AS "DJFM_rn"
    FROM daily_lagged_data
)
,grouped_heat_days AS (
    SELECT
        *
        ,SUM(CASE WHEN (is_jfm AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_jfm
            ORDER BY "JFM_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "JFM_group_id"
        ,SUM(CASE WHEN (is_fma AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_fma
            ORDER BY "FMA_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "FMA_group_id"
        ,SUM(CASE WHEN (is_mam AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_mam
            ORDER BY "MAM_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "MAM_group_id"
        ,SUM(CASE WHEN (is_amj AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_amj
            ORDER BY "AMJ_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "AMJ_group_id"
        ,SUM(CASE WHEN (is_mjj AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_mjj
            ORDER BY "MJJ_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "MJJ_group_id"
        ,SUM(CASE WHEN (is_jja AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_jja
            ORDER BY "JJA_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "JJA_group_id"
        ,SUM(CASE WHEN (is_jas AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_jas
            ORDER BY "JAS_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "JAS_group_id"
        ,SUM(CASE WHEN (is_aso AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_aso
            ORDER BY "ASO_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "ASO_group_id"
        ,SUM(CASE WHEN (is_son AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_son
            ORDER BY "SON_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "SON_group_id"
        ,SUM(CASE WHEN (is_ond AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_ond
            ORDER BY "OND_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "OND_group_id"
        ,SUM(CASE WHEN (is_ndj AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_ndj
            ORDER BY "NDJ_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "NDJ_group_id"
        ,SUM(CASE WHEN (is_dry AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_dry
            ORDER BY "DRY_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "DRY_group_id"
        ,SUM(CASE WHEN (is_wet AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_wet
            ORDER BY "WET_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "WET_group_id"
        ,SUM(CASE WHEN (is_annual AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_annual
            ORDER BY "ANNUAL_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "ANNUAL_group_id"
        ,SUM(CASE WHEN (is_djfm AND (NOT is_heat_day) OR day_gap > 0) THEN 1 ELSE 0 END)
            OVER (PARTITION BY year, station_id, variable_symbol, is_djfm
            ORDER BY "DJFM_rn" ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "DJFM_group_id"
    FROM numbered_heat_days
)
,consecutive_heat_days AS (
    SELECT 
        *
        ,CASE WHEN is_jfm THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "JFM_group_id" ORDER BY "JFM_rn") ELSE NULL END AS "JFM_seq"
        ,CASE WHEN is_fma THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "FMA_group_id" ORDER BY "FMA_rn") ELSE NULL END AS "FMA_seq"
        ,CASE WHEN is_mam THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "MAM_group_id" ORDER BY "MAM_rn") ELSE NULL END AS "MAM_seq"
        ,CASE WHEN is_amj THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "AMJ_group_id" ORDER BY "AMJ_rn") ELSE NULL END AS "AMJ_seq"
        ,CASE WHEN is_mjj THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "MJJ_group_id" ORDER BY "MJJ_rn") ELSE NULL END AS "MJJ_seq"
        ,CASE WHEN is_jja THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "JJA_group_id" ORDER BY "JJA_rn") ELSE NULL END AS "JJA_seq"
        ,CASE WHEN is_jas THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "JAS_group_id" ORDER BY "JAS_rn") ELSE NULL END AS "JAS_seq"
        ,CASE WHEN is_aso THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "ASO_group_id" ORDER BY "ASO_rn") ELSE NULL END AS "ASO_seq"
        ,CASE WHEN is_son THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "SON_group_id" ORDER BY "SON_rn") ELSE NULL END AS "SON_seq"
        ,CASE WHEN is_ond THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "OND_group_id" ORDER BY "OND_rn") ELSE NULL END AS "OND_seq"
        ,CASE WHEN is_ndj THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "NDJ_group_id" ORDER BY "NDJ_rn") ELSE NULL END AS "NDJ_seq"
        ,CASE WHEN is_dry THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "DRY_group_id" ORDER BY "DRY_rn") ELSE NULL END AS "DRY_seq"
        ,CASE WHEN is_wet THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "WET_group_id" ORDER BY "WET_rn") ELSE NULL END AS "WET_seq"
        ,CASE WHEN is_annual THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "ANNUAL_group_id" ORDER BY "ANNUAL_rn") ELSE NULL END AS "ANNUAL_seq"
        ,CASE WHEN is_djfm THEN ROW_NUMBER() OVER (PARTITION BY year, station_id, variable_symbol, "DJFM_group_id" ORDER BY "DJFM_rn") ELSE NULL END AS "DJFM_seq"
        ,CASE WHEN is_jfm THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "JFM_group_id") ELSE NULL END AS "JFM_max_group_day_gap"
        ,CASE WHEN is_fma THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "FMA_group_id") ELSE NULL END AS "FMA_max_group_day_gap"
        ,CASE WHEN is_mam THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "MAM_group_id") ELSE NULL END AS "MAM_max_group_day_gap"
        ,CASE WHEN is_amj THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "AMJ_group_id") ELSE NULL END AS "AMJ_max_group_day_gap"
        ,CASE WHEN is_mjj THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "MJJ_group_id") ELSE NULL END AS "MJJ_max_group_day_gap"
        ,CASE WHEN is_jja THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "JJA_group_id") ELSE NULL END AS "JJA_max_group_day_gap"
        ,CASE WHEN is_jas THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "JAS_group_id") ELSE NULL END AS "JAS_max_group_day_gap"
        ,CASE WHEN is_aso THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "ASO_group_id") ELSE NULL END AS "ASO_max_group_day_gap"
        ,CASE WHEN is_son THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "SON_group_id") ELSE NULL END AS "SON_max_group_day_gap"
        ,CASE WHEN is_ond THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "OND_group_id") ELSE NULL END AS "OND_max_group_day_gap"
        ,CASE WHEN is_ndj THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "NDJ_group_id") ELSE NULL END AS "NDJ_max_group_day_gap"
        ,CASE WHEN is_dry THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "DRY_group_id") ELSE NULL END AS "DRY_max_group_day_gap"
        ,CASE WHEN is_wet THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "WET_group_id") ELSE NULL END AS "WET_max_group_day_gap"
        ,CASE WHEN is_annual THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "ANNUAL_group_id") ELSE NULL END AS "ANNUAL_max_group_day_gap"
        ,CASE WHEN is_djfm THEN MAX(day_gap) OVER (PARTITION BY year, station_id, variable_symbol, "DJFM_group_id") ELSE NULL END AS "DJFM_max_group_day_gap"
    FROM grouped_heat_days
)
,fixed_consecutive_heat_days AS (
    SELECT 
        station_id
        ,variable_symbol
        ,day
        ,day_of_month
        ,month
        ,year
        ,is_heat_day
        ,day_gap
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
        ,CASE WHEN (("JFM_group_id" = 0) OR ("JFM_max_group_day_gap" = 0)) THEN "JFM_seq" ELSE "JFM_seq"-1 END AS "JFM_seq"
        ,CASE WHEN (("FMA_group_id" = 0) OR ("FMA_max_group_day_gap" = 0)) THEN "FMA_seq" ELSE "FMA_seq"-1 END AS "FMA_seq"
        ,CASE WHEN (("MAM_group_id" = 0) OR ("MAM_max_group_day_gap" = 0)) THEN "MAM_seq" ELSE "MAM_seq"-1 END AS "MAM_seq"
        ,CASE WHEN (("AMJ_group_id" = 0) OR ("AMJ_max_group_day_gap" = 0)) THEN "AMJ_seq" ELSE "AMJ_seq"-1 END AS "AMJ_seq"
        ,CASE WHEN (("MJJ_group_id" = 0) OR ("MJJ_max_group_day_gap" = 0)) THEN "MJJ_seq" ELSE "MJJ_seq"-1 END AS "MJJ_seq"
        ,CASE WHEN (("JJA_group_id" = 0) OR ("JJA_max_group_day_gap" = 0)) THEN "JJA_seq" ELSE "JJA_seq"-1 END AS "JJA_seq"
        ,CASE WHEN (("JAS_group_id" = 0) OR ("JAS_max_group_day_gap" = 0)) THEN "JAS_seq" ELSE "JAS_seq"-1 END AS "JAS_seq"
        ,CASE WHEN (("ASO_group_id" = 0) OR ("ASO_max_group_day_gap" = 0)) THEN "ASO_seq" ELSE "ASO_seq"-1 END AS "ASO_seq"
        ,CASE WHEN (("SON_group_id" = 0) OR ("SON_max_group_day_gap" = 0)) THEN "SON_seq" ELSE "SON_seq"-1 END AS "SON_seq"
        ,CASE WHEN (("OND_group_id" = 0) OR ("OND_max_group_day_gap" = 0)) THEN "OND_seq" ELSE "OND_seq"-1 END AS "OND_seq"
        ,CASE WHEN (("NDJ_group_id" = 0) OR ("NDJ_max_group_day_gap" = 0)) THEN "NDJ_seq" ELSE "NDJ_seq"-1 END AS "NDJ_seq"
        ,CASE WHEN (("DRY_group_id" = 0) OR ("DRY_max_group_day_gap" = 0)) THEN "DRY_seq" ELSE "DRY_seq"-1 END AS "DRY_seq"
        ,CASE WHEN (("WET_group_id" = 0) OR ("WET_max_group_day_gap" = 0)) THEN "WET_seq" ELSE "WET_seq"-1 END AS "WET_seq"
        ,CASE WHEN (("ANNUAL_group_id" = 0) OR ("ANNUAL_max_group_day_gap" = 0)) THEN "ANNUAL_seq" ELSE "ANNUAL_seq"-1 END AS "ANNUAL_seq"
        ,CASE WHEN (("DJFM_group_id" = 0) OR ("DJFM_max_group_day_gap" = 0)) THEN "DJFM_seq" ELSE "DJFM_seq"-1 END AS "DJFM_seq"
    FROM consecutive_heat_days
)
-- ,heat_wave_window_calc AS (
--     SELECT
--         *
--         ,MAX(day_gap) OVER (PARTITION BY station_id, variable_symbol, year ORDER BY day ROWS BETWEEN ({{heat_wave_window}}-2) PRECEDING AND CURRENT ROW) AS heat_wave_max_day_gap
--         ,SUM(is_heat_day) OVER (PARTITION BY station_id, variable_symbol, year ORDER BY day ROWS BETWEEN ({{heat_wave_window}}-1) PRECEDING AND CURRENT ROW) AS heat_wave_duration
--     FROM daily_lagged_data
-- )
-- ,heat_wave_calc AS (
--     SELECT
--         *
--         ,CASE 
--             WHEN((heat_wave_max_day_gap > 0) OR (heat_wave_duration < {{heat_wave_window}})) THEN 0
--             ELSE 1
--         END as is_heat_wave
--     FROM heat_wave_window_calc
-- )
,aggreated_data AS (
    SELECT
        st.name AS station
        ,variable_symbol
        ,year
        ,MAX(COALESCE("JFM_seq", 0)) AS "JFM_max_seq"
        ,COUNT(*) FILTER (WHERE is_jfm AND "JFM_seq" >= {{heat_wave_window}}) AS "JFM_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_jfm) AND (day IS NOT NULL)) THEN day END) AS "JFM_count"
        ,MAX(CASE WHEN ((is_jfm) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JFM_max_day_gap"
        ,MAX(COALESCE("FMA_seq", 0)) AS "FMA_max_seq"
        ,COUNT(*) FILTER (WHERE is_fma AND "FMA_seq" >= {{heat_wave_window}}) AS "FMA_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_fma) AND (day IS NOT NULL)) THEN day END) AS "FMA_count"
        ,MAX(CASE WHEN ((is_fma) AND NOT (month = 2 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "FMA_max_day_gap"
        ,MAX(COALESCE("MAM_seq", 0)) AS "MAM_max_seq"
        ,COUNT(*) FILTER (WHERE is_mam AND "MAM_seq" >= {{heat_wave_window}}) AS "MAM_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_mam) AND (day IS NOT NULL)) THEN day END) AS "MAM_count"
        ,MAX(CASE WHEN ((is_mam) AND NOT (month = 3 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MAM_max_day_gap"
        ,MAX(COALESCE("AMJ_seq", 0)) AS "AMJ_max_seq"
        ,COUNT(*) FILTER (WHERE is_amj AND "AMJ_seq" >= {{heat_wave_window}}) AS "AMJ_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_amj) AND (day IS NOT NULL)) THEN day END) AS "AMJ_count"
        ,MAX(CASE WHEN ((is_amj) AND NOT (month = 4 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "AMJ_max_day_gap"
        ,MAX(COALESCE("MJJ_seq", 0)) AS "MJJ_max_seq"
        ,COUNT(*) FILTER (WHERE is_mjj AND "MJJ_seq" >= {{heat_wave_window}}) AS "MJJ_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_mjj) AND (day IS NOT NULL)) THEN day END) AS "MJJ_count"
        ,MAX(CASE WHEN ((is_mjj) AND NOT (month = 5 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MJJ_max_day_gap"
        ,MAX(COALESCE("JJA_seq", 0)) AS "JJA_max_seq"
        ,COUNT(*) FILTER (WHERE is_jja AND "JJA_seq" >= {{heat_wave_window}}) AS "JJA_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_jja) AND (day IS NOT NULL)) THEN day END) AS "JJA_count"
        ,MAX(CASE WHEN ((is_jja) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JJA_max_day_gap"
        ,MAX(COALESCE("JAS_seq", 0)) AS "JAS_max_seq"
        ,COUNT(*) FILTER (WHERE is_jas AND "JAS_seq" >= {{heat_wave_window}}) AS "JAS_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_jas) AND (day IS NOT NULL)) THEN day END) AS "JAS_count"
        ,MAX(CASE WHEN ((is_jas) AND NOT (month = 7 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JAS_max_day_gap"
        ,MAX(COALESCE("ASO_seq", 0)) AS "ASO_max_seq"
        ,COUNT(*) FILTER (WHERE is_aso AND "ASO_seq" >= {{heat_wave_window}}) AS "ASO_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_aso) AND (day IS NOT NULL)) THEN day END) AS "ASO_count"
        ,MAX(CASE WHEN ((is_aso) AND NOT (month = 8 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ASO_max_day_gap"
        ,MAX(COALESCE("SON_seq", 0)) AS "SON_max_seq"
        ,COUNT(*) FILTER (WHERE is_son AND "SON_seq" >= {{heat_wave_window}}) AS "SON_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_son) AND (day IS NOT NULL)) THEN day END) AS "SON_count"
        ,MAX(CASE WHEN ((is_son) AND NOT (month = 9 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "SON_max_day_gap"
        ,MAX(COALESCE("OND_seq", 0)) AS "OND_max_seq"
        ,COUNT(*) FILTER (WHERE is_ond AND "OND_seq" >= {{heat_wave_window}}) AS "OND_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_ond) AND (day IS NOT NULL)) THEN day END) AS "OND_count"
        ,MAX(CASE WHEN ((is_ond) AND NOT (month = 10 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "OND_max_day_gap"
        ,MAX(COALESCE("NDJ_seq", 0)) AS "NDJ_max_seq"
        ,COUNT(*) FILTER (WHERE is_ndj AND "NDJ_seq" >= {{heat_wave_window}}) AS "NDJ_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_ndj) AND (day IS NOT NULL)) THEN day END) AS "NDJ_count"
        ,MAX(CASE WHEN ((is_ndj) AND NOT (month = 11 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "NDJ_max_day_gap"
        ,MAX(COALESCE("DRY_seq", 0)) AS "DRY_max_seq"
        ,COUNT(*) FILTER (WHERE is_dry AND "DRY_seq" >= {{heat_wave_window}}) AS "DRY_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_dry) AND (day IS NOT NULL)) THEN day END) AS "DRY_count"
        ,MAX(CASE WHEN ((is_dry) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "DRY_max_day_gap"
        ,MAX(COALESCE("WET_seq", 0)) AS "WET_max_seq"
        ,COUNT(*) FILTER (WHERE is_wet AND "WET_seq" >= {{heat_wave_window}}) AS "WET_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_wet) AND (day IS NOT NULL)) THEN day END) AS "WET_count"
        ,MAX(CASE WHEN ((is_wet) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "WET_max_day_gap"
        ,MAX(COALESCE("ANNUAL_seq", 0)) AS "ANNUAL_max_seq"
        ,COUNT(*) FILTER (WHERE is_annual AND "ANNUAL_seq" >= {{heat_wave_window}}) AS "ANNUAL_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_annual) AND (day IS NOT NULL)) THEN day END) AS "ANNUAL_count"
        ,MAX(CASE WHEN ((is_annual) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ANNUAL_max_day_gap"
        ,MAX(COALESCE("DJFM_seq", 0)) AS "DJFM_max_seq"
        ,COUNT(*) FILTER (WHERE is_djfm AND "DJFM_seq" >= {{heat_wave_window}}) AS "DJFM_heat_wave_count"
        ,COUNT(DISTINCT CASE WHEN ((is_djfm) AND (day IS NOT NULL)) THEN day END) AS "DJFM_count"
        ,MAX(CASE WHEN ((is_djfm) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "DJFM_max_day_gap"
    FROM fixed_consecutive_heat_days fchd
    JOIN wx_station st ON st.id = fchd.station_id
    GROUP BY st.name, variable_symbol, year
)
,aggregation_pct AS (
    SELECT
        station
        ,variable_symbol
        ,ad.year
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_heat_wave_count" ELSE NULL END AS "JFM_heat_wave_count"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_max_seq" ELSE NULL END AS "JFM_max_seq"
        ,ROUND(((100*(CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_count" ELSE 0 END))::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_heat_wave_count" ELSE NULL END AS "FMA_heat_wave_count"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_max_seq" ELSE NULL END AS "FMA_max_seq"
        ,ROUND(((100*(CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_count" ELSE 0 END))::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_heat_wave_count" ELSE NULL END AS "MAM_heat_wave_count"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_max_seq" ELSE NULL END AS "MAM_max_seq"
        ,ROUND(((100*(CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_count" ELSE 0 END))::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_heat_wave_count" ELSE NULL END AS "AMJ_heat_wave_count"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_max_seq" ELSE NULL END AS "AMJ_max_seq"
        ,ROUND(((100*(CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_count" ELSE 0 END))::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_heat_wave_count" ELSE NULL END AS "MJJ_heat_wave_count"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_max_seq" ELSE NULL END AS "MJJ_max_seq"
        ,ROUND(((100*(CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_count" ELSE 0 END))::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_heat_wave_count" ELSE NULL END AS "JJA_heat_wave_count"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_max_seq" ELSE NULL END AS "JJA_max_seq"
        ,ROUND(((100*(CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_count" ELSE 0 END))::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_heat_wave_count" ELSE NULL END AS "JAS_heat_wave_count"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_max_seq" ELSE NULL END AS "JAS_max_seq"
        ,ROUND(((100*(CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_count" ELSE 0 END))::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_heat_wave_count" ELSE NULL END AS "ASO_heat_wave_count"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_max_seq" ELSE NULL END AS "ASO_max_seq"
        ,ROUND(((100*(CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_count" ELSE 0 END))::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_heat_wave_count" ELSE NULL END AS "SON_heat_wave_count"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_max_seq" ELSE NULL END AS "SON_max_seq"
        ,ROUND(((100*(CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_count" ELSE 0 END))::numeric/"SON_total"::numeric),2) AS "SON (% of days)"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_heat_wave_count" ELSE NULL END AS "OND_heat_wave_count"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_max_seq" ELSE NULL END AS "OND_max_seq"
        ,ROUND(((100*(CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_count" ELSE 0 END))::numeric/"OND_total"::numeric),2) AS "OND (% of days)"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_heat_wave_count" ELSE NULL END AS "NDJ_heat_wave_count"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_max_seq" ELSE NULL END AS "NDJ_max_seq"
        ,ROUND(((100*(CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_count" ELSE 0 END))::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_heat_wave_count" ELSE NULL END AS "DRY_heat_wave_count"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_max_seq" ELSE NULL END AS "DRY_max_seq"
        ,ROUND(((100*(CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_count" ELSE 0 END))::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_heat_wave_count" ELSE NULL END AS "WET_heat_wave_count"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_max_seq" ELSE NULL END AS "WET_max_seq"
        ,ROUND(((100*(CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_count" ELSE 0 END))::numeric/"WET_total"::numeric),2) AS "WET (% of days)"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_heat_wave_count" ELSE NULL END AS "ANNUAL_heat_wave_count"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_max_seq" ELSE NULL END AS "ANNUAL_max_seq"
        ,ROUND(((100*(CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_count" ELSE 0 END))::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_heat_wave_count" ELSE NULL END AS "DJFM_heat_wave_count"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_max_seq" ELSE NULL END AS "DJFM_max_seq"
        ,ROUND(((100*(CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_count" ELSE 0 END))::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"
    FROM aggreated_data ad
    LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
)
SELECT
    station
    ,variable_symbol
    ,year
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_heat_wave_count" ELSE NULL END AS "JFM_1"
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM_max_seq" ELSE NULL END AS "JFM_2"
    ,"JFM (% of days)" 
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_heat_wave_count" ELSE NULL END AS "FMA_1"
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA_max_seq" ELSE NULL END AS "FMA_2"
    ,"FMA (% of days)"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_heat_wave_count" ELSE NULL END AS "MAM_1"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM_max_seq" ELSE NULL END AS "MAM_2"
    ,"MAM (% of days)"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_heat_wave_count" ELSE NULL END AS "AMJ_1"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ_max_seq" ELSE NULL END AS "AMJ_2"
    ,"AMJ (% of days)"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_heat_wave_count" ELSE NULL END AS "MJJ_1"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ_max_seq" ELSE NULL END AS "MJJ_2"
    ,"MJJ (% of days)"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_heat_wave_count" ELSE NULL END AS "JJA_1"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA_max_seq" ELSE NULL END AS "JJA_2"
    ,"JJA (% of days)"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_heat_wave_count" ELSE NULL END AS "JAS_1"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS_max_seq" ELSE NULL END AS "JAS_2"
    ,"JAS (% of days)"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_heat_wave_count" ELSE NULL END AS "ASO_1"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO_max_seq" ELSE NULL END AS "ASO_2"
    ,"ASO (% of days)"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_heat_wave_count" ELSE NULL END AS "SON_1"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON_max_seq" ELSE NULL END AS "SON_2"
    ,"SON (% of days)"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_heat_wave_count" ELSE NULL END AS "OND_1"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND_max_seq" ELSE NULL END AS "OND_2"
    ,"OND (% of days)"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_heat_wave_count" ELSE NULL END AS "NDJ_1"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ_max_seq" ELSE NULL END AS "NDJ_2"
    ,"NDJ (% of days)"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_heat_wave_count" ELSE NULL END AS "DRY_1"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY_max_seq" ELSE NULL END AS "DRY_2"
    ,"DRY (% of days)"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_heat_wave_count" ELSE NULL END AS "WET_1"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET_max_seq" ELSE NULL END AS "WET_2"
    ,"WET (% of days)"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_heat_wave_count" ELSE NULL END AS "ANNUAL_1"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL_max_seq" ELSE NULL END AS "ANNUAL_2"
    ,"ANNUAL (% of days)"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_heat_wave_count" ELSE NULL END AS "DJFM_1"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM_max_seq" ELSE NULL END AS "DJFM_2"
    ,"DJFM (% of days)"
FROM aggregation_pct
ORDER BY year