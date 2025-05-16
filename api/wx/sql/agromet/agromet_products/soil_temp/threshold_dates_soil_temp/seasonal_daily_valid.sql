-- Total number of days for each season and year
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
-- Daily Data from Daily Summary
,daily_data AS (
    SELECT
        station_id
        ,vr.symbol AS variable
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,max_value > {{threshold}} AS is_tsoil_above
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol IN ('TSOIL1', 'TSOIL4')
      AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
)
,extended_data AS(
    SELECT
        station_id
        ,variable
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
        ,is_tsoil_above
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
        ,day - 1 - LAG(day) OVER (PARTITION BY station_id, variable, year ORDER BY day) AS day_gap
    FROM extended_data
    WHERE year BETWEEN {{start_year}} AND {{end_year}}  
)
,aggreated_data AS (
    SELECT
        st.name AS station
        ,variable
        ,year
        ,MIN(day) FILTER (WHERE (is_jfm AND is_tsoil_above)) AS "JFM_first_date"
        ,MAX(day) FILTER (WHERE (is_jfm AND is_tsoil_above)) AS "JFM_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_jfm) AND (day IS NOT NULL))) AS "JFM_count"
        ,MAX(CASE WHEN ((is_jfm) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JFM_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_fma AND is_tsoil_above)) AS "FMA_first_date"
        ,MAX(day) FILTER (WHERE (is_fma AND is_tsoil_above)) AS "FMA_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_fma) AND (day IS NOT NULL))) AS "FMA_count"
        ,MAX(CASE WHEN ((is_fma) AND NOT (month = 2 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "FMA_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_mam AND is_tsoil_above)) AS "MAM_first_date"
        ,MAX(day) FILTER (WHERE (is_mam AND is_tsoil_above)) AS "MAM_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_mam) AND (day IS NOT NULL))) AS "MAM_count"
        ,MAX(CASE WHEN ((is_mam) AND NOT (month = 3 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MAM_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_amj AND is_tsoil_above)) AS "AMJ_first_date"
        ,MAX(day) FILTER (WHERE (is_amj AND is_tsoil_above)) AS "AMJ_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_amj) AND (day IS NOT NULL))) AS "AMJ_count"
        ,MAX(CASE WHEN ((is_amj) AND NOT (month = 4 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "AMJ_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_mjj AND is_tsoil_above)) AS "MJJ_first_date"
        ,MAX(day) FILTER (WHERE (is_mjj AND is_tsoil_above)) AS "MJJ_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_mjj) AND (day IS NOT NULL))) AS "MJJ_count"
        ,MAX(CASE WHEN ((is_mjj) AND NOT (month = 5 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "MJJ_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_jja AND is_tsoil_above)) AS "JJA_first_date"
        ,MAX(day) FILTER (WHERE (is_jja AND is_tsoil_above)) AS "JJA_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_jja) AND (day IS NOT NULL))) AS "JJA_count"
        ,MAX(CASE WHEN ((is_jja) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JJA_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_jas AND is_tsoil_above)) AS "JAS_first_date"
        ,MAX(day) FILTER (WHERE (is_jas AND is_tsoil_above)) AS "JAS_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_jas) AND (day IS NOT NULL))) AS "JAS_count"
        ,MAX(CASE WHEN ((is_jas) AND NOT (month = 7 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "JAS_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_aso AND is_tsoil_above)) AS "ASO_first_date"
        ,MAX(day) FILTER (WHERE (is_aso AND is_tsoil_above)) AS "ASO_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_aso) AND (day IS NOT NULL))) AS "ASO_count"
        ,MAX(CASE WHEN ((is_aso) AND NOT (month = 8 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ASO_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_son AND is_tsoil_above)) AS "SON_first_date"
        ,MAX(day) FILTER (WHERE (is_son AND is_tsoil_above)) AS "SON_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_son) AND (day IS NOT NULL))) AS "SON_count"
        ,MAX(CASE WHEN ((is_son) AND NOT (month = 9 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "SON_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_ond AND is_tsoil_above)) AS "OND_first_date"
        ,MAX(day) FILTER (WHERE (is_ond AND is_tsoil_above)) AS "OND_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_ond) AND (day IS NOT NULL))) AS "OND_count"
        ,MAX(CASE WHEN ((is_ond) AND NOT (month = 10 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "OND_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_ndj AND is_tsoil_above)) AS "NDJ_first_date"
        ,MAX(day) FILTER (WHERE (is_ndj AND is_tsoil_above)) AS "NDJ_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_ndj) AND (day IS NOT NULL))) AS "NDJ_count"
        ,MAX(CASE WHEN ((is_ndj) AND NOT (month = 11 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "NDJ_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_dry AND is_tsoil_above)) AS "DRY_first_date"
        ,MAX(day) FILTER (WHERE (is_dry AND is_tsoil_above)) AS "DRY_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_dry) AND (day IS NOT NULL))) AS "DRY_count"
        ,MAX(CASE WHEN ((is_dry) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "DRY_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_wet AND is_tsoil_above)) AS "WET_first_date"
        ,MAX(day) FILTER (WHERE (is_wet AND is_tsoil_above)) AS "WET_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_wet) AND (day IS NOT NULL))) AS "WET_count"
        ,MAX(CASE WHEN ((is_wet) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "WET_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_annual AND is_tsoil_above)) AS "ANNUAL_first_date"
        ,MAX(day) FILTER (WHERE (is_annual AND is_tsoil_above)) AS "ANNUAL_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_annual) AND (day IS NOT NULL))) AS "ANNUAL_count"
        ,MAX(CASE WHEN ((is_annual) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "ANNUAL_max_day_gap"
        ,MIN(day) FILTER (WHERE (is_djfm AND is_tsoil_above)) AS "DJFM_first_date"
        ,MAX(day) FILTER (WHERE (is_djfm AND is_tsoil_above)) AS "DJFM_last_date"
        ,COUNT(DISTINCT day) FILTER (WHERE ((is_djfm) AND (day IS NOT NULL))) AS "DJFM_count"
        ,MAX(CASE WHEN ((is_djfm) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}})) THEN day_gap ELSE 0 END) AS "DJFM_max_day_gap"
    FROM daily_lagged_data dld
    JOIN wx_station st ON st.id = dld.station_id
    GROUP BY st.name, variable, year
)
SELECT
    station
    ,variable || ' ' || product AS product
    ,ad.year
    ,CASE 
        WHEN "JFM_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("JFM_count"::numeric/"JFM_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "JFM_first_date"::text
                WHEN 'Last Date' THEN "JFM_last_date"::text
                ELSE NULL
            END
    END AS "JFM"
    ,ROUND(100*("JFM_count"::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
    ,CASE 
        WHEN "FMA_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("FMA_count"::numeric/"FMA_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "FMA_first_date"::text
                WHEN 'Last Date' THEN "FMA_last_date"::text
                ELSE NULL
            END
    END AS "FMA"
    ,ROUND(100*("FMA_count"::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"        
    ,CASE 
        WHEN "MAM_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("MAM_count"::numeric/"MAM_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "MAM_first_date"::text
                WHEN 'Last Date' THEN "MAM_last_date"::text
                ELSE NULL
            END
    END AS "MAM"
    ,ROUND(100*("MAM_count"::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"        
    ,CASE 
        WHEN "AMJ_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("AMJ_count"::numeric/"AMJ_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "AMJ_first_date"::text
                WHEN 'Last Date' THEN "AMJ_last_date"::text
                ELSE NULL
            END
    END AS "AMJ"
    ,ROUND(100*("AMJ_count"::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"        
    ,CASE 
        WHEN "MJJ_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("MJJ_count"::numeric/"MJJ_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "MJJ_first_date"::text
                WHEN 'Last Date' THEN "MJJ_last_date"::text
                ELSE NULL
            END
    END AS "MJJ"
    ,ROUND(100*("MJJ_count"::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"        
    ,CASE 
        WHEN "JJA_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("JJA_count"::numeric/"JJA_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "JJA_first_date"::text
                WHEN 'Last Date' THEN "JJA_last_date"::text
                ELSE NULL
            END
    END AS "JJA"
    ,ROUND(100*("JJA_count"::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"        
    ,CASE 
        WHEN "JAS_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("JAS_count"::numeric/"JAS_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "JAS_first_date"::text
                WHEN 'Last Date' THEN "JAS_last_date"::text
                ELSE NULL
            END
    END AS "JAS"
    ,ROUND(100*("JAS_count"::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"        
    ,CASE 
        WHEN "ASO_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("ASO_count"::numeric/"ASO_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "ASO_first_date"::text
                WHEN 'Last Date' THEN "ASO_last_date"::text
                ELSE NULL
            END
    END AS "ASO"
    ,ROUND(100*("ASO_count"::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"        
    ,CASE 
        WHEN "SON_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("SON_count"::numeric/"SON_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "SON_first_date"::text
                WHEN 'Last Date' THEN "SON_last_date"::text
                ELSE NULL
            END
    END AS "SON"
    ,ROUND(100*("SON_count"::numeric/"SON_total"::numeric),2) AS "SON (% of days)"        
    ,CASE 
        WHEN "OND_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("OND_count"::numeric/"OND_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "OND_first_date"::text
                WHEN 'Last Date' THEN "OND_last_date"::text
                ELSE NULL
            END
    END AS "OND"
    ,ROUND(100*("OND_count"::numeric/"OND_total"::numeric),2) AS "OND (% of days)"        
    ,CASE 
        WHEN "NDJ_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("NDJ_count"::numeric/"NDJ_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "NDJ_first_date"::text
                WHEN 'Last Date' THEN "NDJ_last_date"::text
                ELSE NULL
            END
    END AS "NDJ"
    ,ROUND(100*("NDJ_count"::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"        
    ,CASE 
        WHEN "DRY_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("DRY_count"::numeric/"DRY_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "DRY_first_date"::text
                WHEN 'Last Date' THEN "DRY_last_date"::text
                ELSE NULL
            END
    END AS "DRY"
    ,ROUND(100*("DRY_count"::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"        
    ,CASE 
        WHEN "WET_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("WET_count"::numeric/"WET_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "WET_first_date"::text
                WHEN 'Last Date' THEN "WET_last_date"::text
                ELSE NULL
            END
    END AS "WET"
    ,ROUND(100*("WET_count"::numeric/"WET_total"::numeric),2) AS "WET (% of days)"        
    ,CASE 
        WHEN "ANNUAL_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("ANNUAL_count"::numeric/"ANNUAL_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "ANNUAL_first_date"::text
                WHEN 'Last Date' THEN "ANNUAL_last_date"::text
                ELSE NULL
            END
    END AS "ANNUAL"
    ,ROUND(100*("ANNUAL_count"::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"        
    ,CASE 
        WHEN "DJFM_max_day_gap" > {{max_day_gap}} THEN 'Gap Exceeded'
        WHEN ROUND(100*("DJFM_count"::numeric/"DJFM_total"::numeric),2) < (100-{{max_day_pct}}) THEN 'Pct Exceeded'
        ELSE
            CASE product
                WHEN 'First Date' THEN "DJFM_first_date"::text
                WHEN 'Last Date' THEN "DJFM_last_date"::text
                ELSE NULL
            END
    END AS "DJFM"
    ,ROUND(100*("DJFM_count"::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"        
FROM aggreated_data ad
LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
CROSS JOIN (VALUES ('First Date'), ('Last Date')) AS products(product)
ORDER BY station, product, year