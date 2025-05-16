-- Total number of days for each season and year
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
-- Daily Data from Daily Summary
,daily_data AS (
    SELECT
        station_id 
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,max_value AS tmax
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol = 'TEMPMAX'
      AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
)
,heat_wave_data AS (
    SELECT
        station_id
        ,day
        ,day_of_month
        ,month
        ,year
        ,CASE WHEN tmax > {{threshold}} THEN TRUE ELSE FALSE END AS is_hot_day
    FROM daily_data
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
        ,is_hot_day
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
        ,day - 1 - LAG(day) OVER (PARTITION BY station_id, year ORDER BY day) AS day_gap
    FROM extended_data  
    WHERE year BETWEEN {{start_year}} AND {{end_year}}
)
,heat_wave_calc AS (
    SELECT
        station_id
        ,year
        ,UNNEST(ARRAY_AGG(day ORDER BY day)) AS day
        ,UNNEST(ARRAY_AGG(day_of_month ORDER BY day)) AS day_of_month
        ,UNNEST(ARRAY_AGG(month ORDER BY day)) AS month
        ,UNNEST(ARRAY_AGG(is_hot_day ORDER BY day)) AS is_hot_day
        ,UNNEST(ARRAY_AGG(is_jfm ORDER BY day)) AS is_jfm
        ,UNNEST(ARRAY_AGG(is_fma ORDER BY day)) AS is_fma
        ,UNNEST(ARRAY_AGG(is_mam ORDER BY day)) AS is_mam
        ,UNNEST(ARRAY_AGG(is_amj ORDER BY day)) AS is_amj
        ,UNNEST(ARRAY_AGG(is_mjj ORDER BY day)) AS is_mjj
        ,UNNEST(ARRAY_AGG(is_jja ORDER BY day)) AS is_jja
        ,UNNEST(ARRAY_AGG(is_jas ORDER BY day)) AS is_jas
        ,UNNEST(ARRAY_AGG(is_aso ORDER BY day)) AS is_aso
        ,UNNEST(ARRAY_AGG(is_son ORDER BY day)) AS is_son
        ,UNNEST(ARRAY_AGG(is_ond ORDER BY day)) AS is_ond
        ,UNNEST(ARRAY_AGG(is_ndj ORDER BY day)) AS is_ndj
        ,UNNEST(ARRAY_AGG(is_dry ORDER BY day)) AS is_dry
        ,UNNEST(ARRAY_AGG(is_wet ORDER BY day)) AS is_wet
        ,UNNEST(ARRAY_AGG(is_annual ORDER BY day)) AS is_annual
        ,UNNEST(ARRAY_AGG(is_djfm         ORDER BY day)) AS is_djfm        
        ,UNNEST(ARRAY_AGG(day_gap ORDER BY day)) AS day_gap
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_jfm),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_jfm)
        )) AS "JFM_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_fma),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_fma)
        )) AS "FMA_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_mam),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_mam)
        )) AS "MAM_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_amj),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_amj)
        )) AS "AMJ_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_mjj),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_mjj)
        )) AS "MJJ_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_jja),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_jja)
        )) AS "JJA_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_jas),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_jas)
        )) AS "JAS_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_aso),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_aso)
        )) AS "ASO_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_son),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_son)
        )) AS "SON_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_ond),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_ond)
        )) AS "OND_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_ndj),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_ndj)
        )) AS "NDJ_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_dry),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_dry)
        )) AS "DRY_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_wet),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_wet)
        )) AS "WET_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_annual),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_annual)
        )) AS "ANNUAL_hot_seq"
        ,UNNEST(consecutive_flag_calc(
            ARRAY_AGG(is_hot_day ORDER BY day) FILTER(WHERE is_djfm),
            ARRAY_AGG(day_gap > 0 ORDER BY day) FILTER(WHERE is_djfm)
        )) AS "DJFM_hot_seq"
    FROM daily_lagged_data
    GROUP BY station_id, year
)
,aggreated_data AS (
    SELECT
        st.name AS station
        ,year
        ,COALESCE(MAX("JFM_hot_seq") FILTER (WHERE "JFM_hot_seq" >= {{heat_wave_window}}),0) AS "JFM_max_seq"
        ,COUNT(*) FILTER (WHERE is_jfm AND "JFM_hot_seq" = {{heat_wave_window}}) AS "JFM_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_jfm AND is_hot_day) AS "JFM_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_jfm) AND (day IS NOT NULL)) AS "JFM_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_jfm) AND NOT (month=1 AND day_of_month <= {{max_day_gap}})) AS "JFM_max_day_gap"
        ,COALESCE(MAX("FMA_hot_seq") FILTER (WHERE "FMA_hot_seq" >= {{heat_wave_window}}),0) AS "FMA_max_seq"
        ,COUNT(*) FILTER (WHERE is_fma AND "FMA_hot_seq" = {{heat_wave_window}}) AS "FMA_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_fma AND is_hot_day) AS "FMA_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_fma) AND (day IS NOT NULL)) AS "FMA_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_fma) AND NOT (month=2 AND day_of_month <= {{max_day_gap}})) AS "FMA_max_day_gap"
        ,COALESCE(MAX("MAM_hot_seq") FILTER (WHERE "MAM_hot_seq" >= {{heat_wave_window}}),0) AS "MAM_max_seq"
        ,COUNT(*) FILTER (WHERE is_mam AND "MAM_hot_seq" = {{heat_wave_window}}) AS "MAM_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_mam AND is_hot_day) AS "MAM_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_mam) AND (day IS NOT NULL)) AS "MAM_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_mam) AND NOT (month=3 AND day_of_month <= {{max_day_gap}})) AS "MAM_max_day_gap"
        ,COALESCE(MAX("AMJ_hot_seq") FILTER (WHERE "AMJ_hot_seq" >= {{heat_wave_window}}),0) AS "AMJ_max_seq"
        ,COUNT(*) FILTER (WHERE is_amj AND "AMJ_hot_seq" = {{heat_wave_window}}) AS "AMJ_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_amj AND is_hot_day) AS "AMJ_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_amj) AND (day IS NOT NULL)) AS "AMJ_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_amj) AND NOT (month=4 AND day_of_month <= {{max_day_gap}})) AS "AMJ_max_day_gap"
        ,COALESCE(MAX("MJJ_hot_seq") FILTER (WHERE "MJJ_hot_seq" >= {{heat_wave_window}}),0) AS "MJJ_max_seq"
        ,COUNT(*) FILTER (WHERE is_mjj AND "MJJ_hot_seq" = {{heat_wave_window}}) AS "MJJ_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_mjj AND is_hot_day) AS "MJJ_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_mjj) AND (day IS NOT NULL)) AS "MJJ_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_mjj) AND NOT (month=5 AND day_of_month <= {{max_day_gap}})) AS "MJJ_max_day_gap"
        ,COALESCE(MAX("JJA_hot_seq") FILTER (WHERE "JJA_hot_seq" >= {{heat_wave_window}}),0) AS "JJA_max_seq"
        ,COUNT(*) FILTER (WHERE is_jja AND "JJA_hot_seq" = {{heat_wave_window}}) AS "JJA_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_jja AND is_hot_day) AS "JJA_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_jja) AND (day IS NOT NULL)) AS "JJA_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_jja) AND NOT (month=6 AND day_of_month <= {{max_day_gap}})) AS "JJA_max_day_gap"
        ,COALESCE(MAX("JAS_hot_seq") FILTER (WHERE "JAS_hot_seq" >= {{heat_wave_window}}),0) AS "JAS_max_seq"
        ,COUNT(*) FILTER (WHERE is_jas AND "JAS_hot_seq" = {{heat_wave_window}}) AS "JAS_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_jas AND is_hot_day) AS "JAS_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_jas) AND (day IS NOT NULL)) AS "JAS_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_jas) AND NOT (month=7 AND day_of_month <= {{max_day_gap}})) AS "JAS_max_day_gap"
        ,COALESCE(MAX("ASO_hot_seq") FILTER (WHERE "ASO_hot_seq" >= {{heat_wave_window}}),0) AS "ASO_max_seq"
        ,COUNT(*) FILTER (WHERE is_aso AND "ASO_hot_seq" = {{heat_wave_window}}) AS "ASO_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_aso AND is_hot_day) AS "ASO_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_aso) AND (day IS NOT NULL)) AS "ASO_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_aso) AND NOT (month=8 AND day_of_month <= {{max_day_gap}})) AS "ASO_max_day_gap"
        ,COALESCE(MAX("SON_hot_seq") FILTER (WHERE "SON_hot_seq" >= {{heat_wave_window}}),0) AS "SON_max_seq"
        ,COUNT(*) FILTER (WHERE is_son AND "SON_hot_seq" = {{heat_wave_window}}) AS "SON_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_son AND is_hot_day) AS "SON_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_son) AND (day IS NOT NULL)) AS "SON_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_son) AND NOT (month=9 AND day_of_month <= {{max_day_gap}})) AS "SON_max_day_gap"
        ,COALESCE(MAX("OND_hot_seq") FILTER (WHERE "OND_hot_seq" >= {{heat_wave_window}}),0) AS "OND_max_seq"
        ,COUNT(*) FILTER (WHERE is_ond AND "OND_hot_seq" = {{heat_wave_window}}) AS "OND_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_ond AND is_hot_day) AS "OND_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_ond) AND (day IS NOT NULL)) AS "OND_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_ond) AND NOT (month=10 AND day_of_month <= {{max_day_gap}})) AS "OND_max_day_gap"
        ,COALESCE(MAX("NDJ_hot_seq") FILTER (WHERE "NDJ_hot_seq" >= {{heat_wave_window}}),0) AS "NDJ_max_seq"
        ,COUNT(*) FILTER (WHERE is_ndj AND "NDJ_hot_seq" = {{heat_wave_window}}) AS "NDJ_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_ndj AND is_hot_day) AS "NDJ_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_ndj) AND (day IS NOT NULL)) AS "NDJ_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_ndj) AND NOT (month=11 AND day_of_month <= {{max_day_gap}})) AS "NDJ_max_day_gap"
        ,COALESCE(MAX("DRY_hot_seq") FILTER (WHERE "DRY_hot_seq" >= {{heat_wave_window}}),0) AS "DRY_max_seq"
        ,COUNT(*) FILTER (WHERE is_dry AND "DRY_hot_seq" = {{heat_wave_window}}) AS "DRY_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_dry AND is_hot_day) AS "DRY_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_dry) AND (day IS NOT NULL)) AS "DRY_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_dry) AND NOT (month=0 AND day_of_month <= {{max_day_gap}})) AS "DRY_max_day_gap"
        ,COALESCE(MAX("WET_hot_seq") FILTER (WHERE "WET_hot_seq" >= {{heat_wave_window}}),0) AS "WET_max_seq"
        ,COUNT(*) FILTER (WHERE is_wet AND "WET_hot_seq" = {{heat_wave_window}}) AS "WET_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_wet AND is_hot_day) AS "WET_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_wet) AND (day IS NOT NULL)) AS "WET_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_wet) AND NOT (month=6 AND day_of_month <= {{max_day_gap}})) AS "WET_max_day_gap"
        ,COALESCE(MAX("ANNUAL_hot_seq") FILTER (WHERE "ANNUAL_hot_seq" >= {{heat_wave_window}}),0) AS "ANNUAL_max_seq"
        ,COUNT(*) FILTER (WHERE is_annual AND "ANNUAL_hot_seq" = {{heat_wave_window}}) AS "ANNUAL_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_annual AND is_hot_day) AS "ANNUAL_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_annual) AND (day IS NOT NULL)) AS "ANNUAL_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_annual) AND NOT (month=1 AND day_of_month <= {{max_day_gap}})) AS "ANNUAL_max_day_gap"
        ,COALESCE(MAX("DJFM_hot_seq") FILTER (WHERE "DJFM_hot_seq" >= {{heat_wave_window}}),0) AS "DJFM_max_seq"
        ,COUNT(*) FILTER (WHERE is_djfm AND "DJFM_hot_seq" = {{heat_wave_window}}) AS "DJFM_heat_wave_events"
        ,COUNT(*) FILTER (WHERE is_djfm AND is_hot_day) AS "DJFM_hot_days"
        ,COUNT(DISTINCT day) FILTER(WHERE (is_djfm) AND (day IS NOT NULL)) AS "DJFM_count"
        ,MAX(COALESCE(day_gap)) FILTER(WHERE (is_djfm) AND NOT (month=0 AND day_of_month <= {{max_day_gap}})) AS "DJFM_max_day_gap"
    FROM heat_wave_calc hwc
    JOIN wx_station st ON st.id = hwc.station_id
    GROUP BY st.name, year
)
SELECT
    station
    ,product
    ,ad.year
    ,CASE 
        WHEN "JFM_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("JFM_count"::numeric/"JFM_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("JFM_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("JFM_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("JFM_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "JFM"
    ,ROUND(100*("JFM_count"::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
    ,CASE 
        WHEN "FMA_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("FMA_count"::numeric/"FMA_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("FMA_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("FMA_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("FMA_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "FMA"
    ,ROUND(100*("FMA_count"::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"        
    ,CASE 
        WHEN "MAM_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("MAM_count"::numeric/"MAM_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("MAM_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("MAM_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("MAM_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "MAM"
    ,ROUND(100*("MAM_count"::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"        
    ,CASE 
        WHEN "AMJ_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("AMJ_count"::numeric/"AMJ_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("AMJ_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("AMJ_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("AMJ_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "AMJ"
    ,ROUND(100*("AMJ_count"::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"        
    ,CASE 
        WHEN "MJJ_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("MJJ_count"::numeric/"MJJ_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("MJJ_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("MJJ_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("MJJ_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "MJJ"
    ,ROUND(100*("MJJ_count"::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"        
    ,CASE 
        WHEN "JJA_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("JJA_count"::numeric/"JJA_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("JJA_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("JJA_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("JJA_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "JJA"
    ,ROUND(100*("JJA_count"::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"        
    ,CASE 
        WHEN "JAS_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("JAS_count"::numeric/"JAS_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("JAS_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("JAS_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("JAS_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "JAS"
    ,ROUND(100*("JAS_count"::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"        
    ,CASE 
        WHEN "ASO_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("ASO_count"::numeric/"ASO_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("ASO_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("ASO_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("ASO_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "ASO"
    ,ROUND(100*("ASO_count"::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"        
    ,CASE 
        WHEN "SON_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("SON_count"::numeric/"SON_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("SON_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("SON_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("SON_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "SON"
    ,ROUND(100*("SON_count"::numeric/"SON_total"::numeric),2) AS "SON (% of days)"        
    ,CASE 
        WHEN "OND_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("OND_count"::numeric/"OND_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("OND_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("OND_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("OND_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "OND"
    ,ROUND(100*("OND_count"::numeric/"OND_total"::numeric),2) AS "OND (% of days)"        
    ,CASE 
        WHEN "NDJ_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("NDJ_count"::numeric/"NDJ_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("NDJ_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("NDJ_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("NDJ_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "NDJ"
    ,ROUND(100*("NDJ_count"::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"        
    ,CASE 
        WHEN "DRY_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("DRY_count"::numeric/"DRY_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("DRY_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("DRY_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("DRY_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "DRY"
    ,ROUND(100*("DRY_count"::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"        
    ,CASE 
        WHEN "WET_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("WET_count"::numeric/"WET_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("WET_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("WET_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("WET_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "WET"
    ,ROUND(100*("WET_count"::numeric/"WET_total"::numeric),2) AS "WET (% of days)"        
    ,CASE 
        WHEN "ANNUAL_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("ANNUAL_count"::numeric/"ANNUAL_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("ANNUAL_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("ANNUAL_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("ANNUAL_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "ANNUAL"
    ,ROUND(100*("ANNUAL_count"::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"        
    ,CASE 
        WHEN "DJFM_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("DJFM_count"::numeric/"DJFM_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'longest heat wave duration' THEN ROUND("DJFM_max_seq"::numeric,2)::text
                WHEN 'number heat wave events' THEN ROUND("DJFM_heat_wave_events"::numeric,2)::text
                WHEN 'number of hot days' THEN ROUND("DJFM_hot_days"::numeric,2)::text
                ELSE NULL
            END
    END AS "DJFM"
    ,ROUND(100*("DJFM_count"::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"        
FROM aggreated_data ad
LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
CROSS JOIN (VALUES ('number of hot days'), ('longest heat wave duration'), ('number heat wave events')) AS products(product)
ORDER BY station, product, year