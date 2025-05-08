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
,hourly_data AS (
    SELECT
        station_id 
        ,DATE(datetime AT TIME ZONE '{{timezone}}') AS day
        ,EXTRACT(HOUR FROM datetime AT TIME ZONE '{{timezone}}') AS hour
        ,min_value
        ,max_value
        ,avg_value
        ,sum_value
    FROM hourly_summary hs
    JOIN wx_variable vr ON vr.id = hs.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol = 'TEMP'
      AND datetime AT TIME ZONE '{{timezone}}' >= '{{ start_date }}'
      AND datetime AT TIME ZONE '{{timezone}}' < '{{ end_date }}'
)
,daily_data AS (
    SELECT
        station_id
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year        
        ,COUNT(DISTINCT day) AS total_hours
        ,MIN(min_value) AS tmin
        ,MAX(max_value) AS tmax
    FROM hourly_data
    GROUP BY station_id, day
)
,daily_data_valid AS (
    SELECT
        station_id
        ,day
        ,day_of_month
        ,month
        ,year
        ,tmin
        ,tmax
    FROM daily_data
    WHERE 100*(total_hours::numeric/24) > (100-{{max_hour_pct}})
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
        ,tmin
        ,tmax
    FROM daily_data_valid
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM daily_data_valid
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
        ,COUNT(*) FILTER(WHERE ((is_jfm) AND {{threshold}} > tmin)) AS "JFM_below"
        ,COUNT(*) FILTER(WHERE ((is_jfm) AND {{threshold}} < tmax)) AS "JFM_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_jfm) AND (day IS NOT NULL))) AS "JFM_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_jfm) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}}))) AS "JFM_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_fma) AND {{threshold}} > tmin)) AS "FMA_below"
        ,COUNT(*) FILTER(WHERE ((is_fma) AND {{threshold}} < tmax)) AS "FMA_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_fma) AND (day IS NOT NULL))) AS "FMA_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_fma) AND NOT (month = 2 AND day_of_month <= {{max_day_gap}}))) AS "FMA_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_mam) AND {{threshold}} > tmin)) AS "MAM_below"
        ,COUNT(*) FILTER(WHERE ((is_mam) AND {{threshold}} < tmax)) AS "MAM_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_mam) AND (day IS NOT NULL))) AS "MAM_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_mam) AND NOT (month = 3 AND day_of_month <= {{max_day_gap}}))) AS "MAM_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_amj) AND {{threshold}} > tmin)) AS "AMJ_below"
        ,COUNT(*) FILTER(WHERE ((is_amj) AND {{threshold}} < tmax)) AS "AMJ_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_amj) AND (day IS NOT NULL))) AS "AMJ_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_amj) AND NOT (month = 4 AND day_of_month <= {{max_day_gap}}))) AS "AMJ_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_mjj) AND {{threshold}} > tmin)) AS "MJJ_below"
        ,COUNT(*) FILTER(WHERE ((is_mjj) AND {{threshold}} < tmax)) AS "MJJ_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_mjj) AND (day IS NOT NULL))) AS "MJJ_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_mjj) AND NOT (month = 5 AND day_of_month <= {{max_day_gap}}))) AS "MJJ_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_jja) AND {{threshold}} > tmin)) AS "JJA_below"
        ,COUNT(*) FILTER(WHERE ((is_jja) AND {{threshold}} < tmax)) AS "JJA_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_jja) AND (day IS NOT NULL))) AS "JJA_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_jja) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}}))) AS "JJA_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_jas) AND {{threshold}} > tmin)) AS "JAS_below"
        ,COUNT(*) FILTER(WHERE ((is_jas) AND {{threshold}} < tmax)) AS "JAS_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_jas) AND (day IS NOT NULL))) AS "JAS_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_jas) AND NOT (month = 7 AND day_of_month <= {{max_day_gap}}))) AS "JAS_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_aso) AND {{threshold}} > tmin)) AS "ASO_below"
        ,COUNT(*) FILTER(WHERE ((is_aso) AND {{threshold}} < tmax)) AS "ASO_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_aso) AND (day IS NOT NULL))) AS "ASO_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_aso) AND NOT (month = 8 AND day_of_month <= {{max_day_gap}}))) AS "ASO_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_son) AND {{threshold}} > tmin)) AS "SON_below"
        ,COUNT(*) FILTER(WHERE ((is_son) AND {{threshold}} < tmax)) AS "SON_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_son) AND (day IS NOT NULL))) AS "SON_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_son) AND NOT (month = 9 AND day_of_month <= {{max_day_gap}}))) AS "SON_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_ond) AND {{threshold}} > tmin)) AS "OND_below"
        ,COUNT(*) FILTER(WHERE ((is_ond) AND {{threshold}} < tmax)) AS "OND_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_ond) AND (day IS NOT NULL))) AS "OND_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_ond) AND NOT (month = 10 AND day_of_month <= {{max_day_gap}}))) AS "OND_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_ndj) AND {{threshold}} > tmin)) AS "NDJ_below"
        ,COUNT(*) FILTER(WHERE ((is_ndj) AND {{threshold}} < tmax)) AS "NDJ_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_ndj) AND (day IS NOT NULL))) AS "NDJ_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_ndj) AND NOT (month = 11 AND day_of_month <= {{max_day_gap}}))) AS "NDJ_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_dry) AND {{threshold}} > tmin)) AS "DRY_below"
        ,COUNT(*) FILTER(WHERE ((is_dry) AND {{threshold}} < tmax)) AS "DRY_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_dry) AND (day IS NOT NULL))) AS "DRY_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_dry) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}}))) AS "DRY_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_wet) AND {{threshold}} > tmin)) AS "WET_below"
        ,COUNT(*) FILTER(WHERE ((is_wet) AND {{threshold}} < tmax)) AS "WET_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_wet) AND (day IS NOT NULL))) AS "WET_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_wet) AND NOT (month = 6 AND day_of_month <= {{max_day_gap}}))) AS "WET_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_annual) AND {{threshold}} > tmin)) AS "ANNUAL_below"
        ,COUNT(*) FILTER(WHERE ((is_annual) AND {{threshold}} < tmax)) AS "ANNUAL_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_annual) AND (day IS NOT NULL))) AS "ANNUAL_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_annual) AND NOT (month = 1 AND day_of_month <= {{max_day_gap}}))) AS "ANNUAL_max_day_gap"
        ,COUNT(*) FILTER(WHERE ((is_djfm) AND {{threshold}} > tmin)) AS "DJFM_below"
        ,COUNT(*) FILTER(WHERE ((is_djfm) AND {{threshold}} < tmax)) AS "DJFM_above"
        ,COUNT(DISTINCT DAY)  FILTER(WHERE ((is_djfm) AND (day IS NOT NULL))) AS "DJFM_count"
        ,MAX(COALESCE(day_gap,0)) FILTER(WHERE ((is_djfm) AND NOT (month = 0 AND day_of_month <= {{max_day_gap}}))) AS "DJFM_max_day_gap"
    FROM daily_lagged_data dld
    JOIN wx_station st ON st.id = dld.station_id
    GROUP BY st.name, year
)
,aggregation_pct AS (
    SELECT
        station
        ,ad.year
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_below" ELSE NULL END AS "JFM_below"
        ,CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_above" ELSE NULL END AS "JFM_above"
        ,ROUND(((100*(CASE WHEN "JFM_max_day_gap" <= {{max_day_gap}} THEN "JFM_count" ELSE 0 END))::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_below" ELSE NULL END AS "FMA_below"
        ,CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_above" ELSE NULL END AS "FMA_above"
        ,ROUND(((100*(CASE WHEN "FMA_max_day_gap" <= {{max_day_gap}} THEN "FMA_count" ELSE 0 END))::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_below" ELSE NULL END AS "MAM_below"
        ,CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_above" ELSE NULL END AS "MAM_above"
        ,ROUND(((100*(CASE WHEN "MAM_max_day_gap" <= {{max_day_gap}} THEN "MAM_count" ELSE 0 END))::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_below" ELSE NULL END AS "AMJ_below"
        ,CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_above" ELSE NULL END AS "AMJ_above"
        ,ROUND(((100*(CASE WHEN "AMJ_max_day_gap" <= {{max_day_gap}} THEN "AMJ_count" ELSE 0 END))::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_below" ELSE NULL END AS "MJJ_below"
        ,CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_above" ELSE NULL END AS "MJJ_above"
        ,ROUND(((100*(CASE WHEN "MJJ_max_day_gap" <= {{max_day_gap}} THEN "MJJ_count" ELSE 0 END))::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_below" ELSE NULL END AS "JJA_below"
        ,CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_above" ELSE NULL END AS "JJA_above"
        ,ROUND(((100*(CASE WHEN "JJA_max_day_gap" <= {{max_day_gap}} THEN "JJA_count" ELSE 0 END))::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_below" ELSE NULL END AS "JAS_below"
        ,CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_above" ELSE NULL END AS "JAS_above"
        ,ROUND(((100*(CASE WHEN "JAS_max_day_gap" <= {{max_day_gap}} THEN "JAS_count" ELSE 0 END))::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_below" ELSE NULL END AS "ASO_below"
        ,CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_above" ELSE NULL END AS "ASO_above"
        ,ROUND(((100*(CASE WHEN "ASO_max_day_gap" <= {{max_day_gap}} THEN "ASO_count" ELSE 0 END))::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_below" ELSE NULL END AS "SON_below"
        ,CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_above" ELSE NULL END AS "SON_above"
        ,ROUND(((100*(CASE WHEN "SON_max_day_gap" <= {{max_day_gap}} THEN "SON_count" ELSE 0 END))::numeric/"SON_total"::numeric),2) AS "SON (% of days)"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_below" ELSE NULL END AS "OND_below"
        ,CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_above" ELSE NULL END AS "OND_above"
        ,ROUND(((100*(CASE WHEN "OND_max_day_gap" <= {{max_day_gap}} THEN "OND_count" ELSE 0 END))::numeric/"OND_total"::numeric),2) AS "OND (% of days)"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_below" ELSE NULL END AS "NDJ_below"
        ,CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_above" ELSE NULL END AS "NDJ_above"
        ,ROUND(((100*(CASE WHEN "NDJ_max_day_gap" <= {{max_day_gap}} THEN "NDJ_count" ELSE 0 END))::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_below" ELSE NULL END AS "DRY_below"
        ,CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_above" ELSE NULL END AS "DRY_above"
        ,ROUND(((100*(CASE WHEN "DRY_max_day_gap" <= {{max_day_gap}} THEN "DRY_count" ELSE 0 END))::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_below" ELSE NULL END AS "WET_below"
        ,CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_above" ELSE NULL END AS "WET_above"
        ,ROUND(((100*(CASE WHEN "WET_max_day_gap" <= {{max_day_gap}} THEN "WET_count" ELSE 0 END))::numeric/"WET_total"::numeric),2) AS "WET (% of days)"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_below" ELSE NULL END AS "ANNUAL_below"
        ,CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_above" ELSE NULL END AS "ANNUAL_above"
        ,ROUND(((100*(CASE WHEN "ANNUAL_max_day_gap" <= {{max_day_gap}} THEN "ANNUAL_count" ELSE 0 END))::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_below" ELSE NULL END AS "DJFM_below"
        ,CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_above" ELSE NULL END AS "DJFM_above"
        ,ROUND(((100*(CASE WHEN "DJFM_max_day_gap" <= {{max_day_gap}} THEN "DJFM_count" ELSE 0 END))::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"
    FROM aggreated_data ad
    LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
)
SELECT
    station
    ,product 
    ,year
    ,CASE 
        WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "JFM_below"
                WHEN 'above' THEN "JFM_above"
            END
        ELSE NULL
    END AS "JFM_1"
    ,"JFM (% of days)" 
    ,CASE 
        WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "FMA_below"
                WHEN 'above' THEN "FMA_above"
            END
        ELSE NULL
    END AS "FMA_1"
    ,"FMA (% of days)"
    ,CASE 
        WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "MAM_below"
                WHEN 'above' THEN "MAM_above"
            END
        ELSE NULL
    END AS "MAM_1"
    ,"MAM (% of days)"
    ,CASE 
        WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "AMJ_below"
                WHEN 'above' THEN "AMJ_above"
            END
        ELSE NULL
    END AS "AMJ_1"
    ,"AMJ (% of days)"
    ,CASE 
        WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "MJJ_below"
                WHEN 'above' THEN "MJJ_above"
            END
        ELSE NULL
    END AS "MJJ_1"
    ,"MJJ (% of days)"
    ,CASE 
        WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "JJA_below"
                WHEN 'above' THEN "JJA_above"
            END
        ELSE NULL
    END AS "JJA_1"
    ,"JJA (% of days)"
    ,CASE 
        WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "JAS_below"
                WHEN 'above' THEN "JAS_above"
            END
        ELSE NULL
    END AS "JAS_1"
    ,"JAS (% of days)"
    ,CASE 
        WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "ASO_below"
                WHEN 'above' THEN "ASO_above"
            END
        ELSE NULL
    END AS "ASO_1"
    ,"ASO (% of days)"
    ,CASE 
        WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "SON_below"
                WHEN 'above' THEN "SON_above"
            END
        ELSE NULL
    END AS "SON_1"
    ,"SON (% of days)"
    ,CASE 
        WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "OND_below"
                WHEN 'above' THEN "OND_above"
            END
        ELSE NULL
    END AS "OND_1"
    ,"OND (% of days)"
    ,CASE 
        WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "NDJ_below"
                WHEN 'above' THEN "NDJ_above"
            END
        ELSE NULL
    END AS "NDJ_1"
    ,"NDJ (% of days)"
    ,CASE 
        WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "DRY_below"
                WHEN 'above' THEN "DRY_above"
            END
        ELSE NULL
    END AS "DRY_1"
    ,"DRY (% of days)"
    ,CASE 
        WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "WET_below"
                WHEN 'above' THEN "WET_above"
            END
        ELSE NULL
    END AS "WET_1"
    ,"WET (% of days)"
    ,CASE 
        WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "ANNUAL_below"
                WHEN 'above' THEN "ANNUAL_above"
            END
        ELSE NULL
    END AS "ANNUAL_1"
    ,"ANNUAL (% of days)"
    ,CASE 
        WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN
            CASE product
                WHEN 'below' THEN "DJFM_below"
                WHEN 'above' THEN "DJFM_above"
            END
        ELSE NULL
    END AS "DJFM_1"
    ,"DJFM (% of days)"
FROM aggregation_pct 
CROSS JOIN (VALUES ('below'), ('above')) AS products(product)
ORDER BY year