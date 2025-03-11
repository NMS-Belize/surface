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
,daily_wind_direction AS (
    SELECT
        station_id 
        ,day
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
        END AS wind_direction
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol = 'WNDDIR'
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
        ,wind_direction
    FROM daily_wind_direction
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM daily_wind_direction
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
        ,COUNT(CASE WHEN (month IN (1, 2, 3) AND wind_direction = 'N') THEN 1 END) AS "JFM_N"
        ,COUNT(CASE WHEN (month IN (1, 2, 3) AND wind_direction = 'NE') THEN 1 END) AS "JFM_NE"
        ,COUNT(CASE WHEN (month IN (1, 2, 3) AND wind_direction = 'E') THEN 1 END) AS "JFM_E"
        ,COUNT(CASE WHEN (month IN (1, 2, 3) AND wind_direction = 'SE') THEN 1 END) AS "JFM_SE"
        ,COUNT(CASE WHEN (month IN (1, 2, 3) AND wind_direction = 'S') THEN 1 END) AS "JFM_S"
        ,COUNT(CASE WHEN (month IN (1, 2, 3) AND wind_direction = 'SW') THEN 1 END) AS "JFM_SW"
        ,COUNT(CASE WHEN (month IN (1, 2, 3) AND wind_direction = 'W') THEN 1 END) AS "JFM_W"
        ,COUNT(CASE WHEN (month IN (1, 2, 3) AND wind_direction = 'NW') THEN 1 END) AS "JFM_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (1, 2, 3)) AND (day IS NOT NULL)) THEN day END) AS "JFM_count"
        ,MAX(CASE
                WHEN ((month IN (1, 2, 3)) AND NOT (month = 1 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "JFM_max_day_diff"
        ,COUNT(CASE WHEN (month IN (2, 3, 4) AND wind_direction = 'N') THEN 1 END) AS "FMA_N"
        ,COUNT(CASE WHEN (month IN (2, 3, 4) AND wind_direction = 'NE') THEN 1 END) AS "FMA_NE"
        ,COUNT(CASE WHEN (month IN (2, 3, 4) AND wind_direction = 'E') THEN 1 END) AS "FMA_E"
        ,COUNT(CASE WHEN (month IN (2, 3, 4) AND wind_direction = 'SE') THEN 1 END) AS "FMA_SE"
        ,COUNT(CASE WHEN (month IN (2, 3, 4) AND wind_direction = 'S') THEN 1 END) AS "FMA_S"
        ,COUNT(CASE WHEN (month IN (2, 3, 4) AND wind_direction = 'SW') THEN 1 END) AS "FMA_SW"
        ,COUNT(CASE WHEN (month IN (2, 3, 4) AND wind_direction = 'W') THEN 1 END) AS "FMA_W"
        ,COUNT(CASE WHEN (month IN (2, 3, 4) AND wind_direction = 'NW') THEN 1 END) AS "FMA_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (2, 3, 4)) AND (day IS NOT NULL)) THEN day END) AS "FMA_count"
        ,MAX(CASE
                WHEN ((month IN (2, 3, 4)) AND NOT (month = 2 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "FMA_max_day_diff"
        ,COUNT(CASE WHEN (month IN (3, 4, 5) AND wind_direction = 'N') THEN 1 END) AS "MAM_N"
        ,COUNT(CASE WHEN (month IN (3, 4, 5) AND wind_direction = 'NE') THEN 1 END) AS "MAM_NE"
        ,COUNT(CASE WHEN (month IN (3, 4, 5) AND wind_direction = 'E') THEN 1 END) AS "MAM_E"
        ,COUNT(CASE WHEN (month IN (3, 4, 5) AND wind_direction = 'SE') THEN 1 END) AS "MAM_SE"
        ,COUNT(CASE WHEN (month IN (3, 4, 5) AND wind_direction = 'S') THEN 1 END) AS "MAM_S"
        ,COUNT(CASE WHEN (month IN (3, 4, 5) AND wind_direction = 'SW') THEN 1 END) AS "MAM_SW"
        ,COUNT(CASE WHEN (month IN (3, 4, 5) AND wind_direction = 'W') THEN 1 END) AS "MAM_W"
        ,COUNT(CASE WHEN (month IN (3, 4, 5) AND wind_direction = 'NW') THEN 1 END) AS "MAM_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (3, 4, 5)) AND (day IS NOT NULL)) THEN day END) AS "MAM_count"
        ,MAX(CASE
                WHEN ((month IN (3, 4, 5)) AND NOT (month = 3 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "MAM_max_day_diff"
        ,COUNT(CASE WHEN (month IN (4, 5, 6) AND wind_direction = 'N') THEN 1 END) AS "AMJ_N"
        ,COUNT(CASE WHEN (month IN (4, 5, 6) AND wind_direction = 'NE') THEN 1 END) AS "AMJ_NE"
        ,COUNT(CASE WHEN (month IN (4, 5, 6) AND wind_direction = 'E') THEN 1 END) AS "AMJ_E"
        ,COUNT(CASE WHEN (month IN (4, 5, 6) AND wind_direction = 'SE') THEN 1 END) AS "AMJ_SE"
        ,COUNT(CASE WHEN (month IN (4, 5, 6) AND wind_direction = 'S') THEN 1 END) AS "AMJ_S"
        ,COUNT(CASE WHEN (month IN (4, 5, 6) AND wind_direction = 'SW') THEN 1 END) AS "AMJ_SW"
        ,COUNT(CASE WHEN (month IN (4, 5, 6) AND wind_direction = 'W') THEN 1 END) AS "AMJ_W"
        ,COUNT(CASE WHEN (month IN (4, 5, 6) AND wind_direction = 'NW') THEN 1 END) AS "AMJ_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (4, 5, 6)) AND (day IS NOT NULL)) THEN day END) AS "AMJ_count"
        ,MAX(CASE
                WHEN ((month IN (4, 5, 6)) AND NOT (month = 4 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "AMJ_max_day_diff"
        ,COUNT(CASE WHEN (month IN (5, 6, 7) AND wind_direction = 'N') THEN 1 END) AS "MJJ_N"
        ,COUNT(CASE WHEN (month IN (5, 6, 7) AND wind_direction = 'NE') THEN 1 END) AS "MJJ_NE"
        ,COUNT(CASE WHEN (month IN (5, 6, 7) AND wind_direction = 'E') THEN 1 END) AS "MJJ_E"
        ,COUNT(CASE WHEN (month IN (5, 6, 7) AND wind_direction = 'SE') THEN 1 END) AS "MJJ_SE"
        ,COUNT(CASE WHEN (month IN (5, 6, 7) AND wind_direction = 'S') THEN 1 END) AS "MJJ_S"
        ,COUNT(CASE WHEN (month IN (5, 6, 7) AND wind_direction = 'SW') THEN 1 END) AS "MJJ_SW"
        ,COUNT(CASE WHEN (month IN (5, 6, 7) AND wind_direction = 'W') THEN 1 END) AS "MJJ_W"
        ,COUNT(CASE WHEN (month IN (5, 6, 7) AND wind_direction = 'NW') THEN 1 END) AS "MJJ_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (5, 6, 7)) AND (day IS NOT NULL)) THEN day END) AS "MJJ_count"
        ,MAX(CASE
                WHEN ((month IN (5, 6, 7)) AND NOT (month = 5 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "MJJ_max_day_diff"
        ,COUNT(CASE WHEN (month IN (6, 7, 8) AND wind_direction = 'N') THEN 1 END) AS "JJA_N"
        ,COUNT(CASE WHEN (month IN (6, 7, 8) AND wind_direction = 'NE') THEN 1 END) AS "JJA_NE"
        ,COUNT(CASE WHEN (month IN (6, 7, 8) AND wind_direction = 'E') THEN 1 END) AS "JJA_E"
        ,COUNT(CASE WHEN (month IN (6, 7, 8) AND wind_direction = 'SE') THEN 1 END) AS "JJA_SE"
        ,COUNT(CASE WHEN (month IN (6, 7, 8) AND wind_direction = 'S') THEN 1 END) AS "JJA_S"
        ,COUNT(CASE WHEN (month IN (6, 7, 8) AND wind_direction = 'SW') THEN 1 END) AS "JJA_SW"
        ,COUNT(CASE WHEN (month IN (6, 7, 8) AND wind_direction = 'W') THEN 1 END) AS "JJA_W"
        ,COUNT(CASE WHEN (month IN (6, 7, 8) AND wind_direction = 'NW') THEN 1 END) AS "JJA_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (6, 7, 8)) AND (day IS NOT NULL)) THEN day END) AS "JJA_count"
        ,MAX(CASE
                WHEN ((month IN (6, 7, 8)) AND NOT (month = 6 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "JJA_max_day_diff"
        ,COUNT(CASE WHEN (month IN (7, 8, 9) AND wind_direction = 'N') THEN 1 END) AS "JAS_N"
        ,COUNT(CASE WHEN (month IN (7, 8, 9) AND wind_direction = 'NE') THEN 1 END) AS "JAS_NE"
        ,COUNT(CASE WHEN (month IN (7, 8, 9) AND wind_direction = 'E') THEN 1 END) AS "JAS_E"
        ,COUNT(CASE WHEN (month IN (7, 8, 9) AND wind_direction = 'SE') THEN 1 END) AS "JAS_SE"
        ,COUNT(CASE WHEN (month IN (7, 8, 9) AND wind_direction = 'S') THEN 1 END) AS "JAS_S"
        ,COUNT(CASE WHEN (month IN (7, 8, 9) AND wind_direction = 'SW') THEN 1 END) AS "JAS_SW"
        ,COUNT(CASE WHEN (month IN (7, 8, 9) AND wind_direction = 'W') THEN 1 END) AS "JAS_W"
        ,COUNT(CASE WHEN (month IN (7, 8, 9) AND wind_direction = 'NW') THEN 1 END) AS "JAS_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (7, 8, 9)) AND (day IS NOT NULL)) THEN day END) AS "JAS_count"
        ,MAX(CASE
                WHEN ((month IN (7, 8, 9)) AND NOT (month = 7 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "JAS_max_day_diff"
        ,COUNT(CASE WHEN (month IN (8, 9, 10) AND wind_direction = 'N') THEN 1 END) AS "ASO_N"
        ,COUNT(CASE WHEN (month IN (8, 9, 10) AND wind_direction = 'NE') THEN 1 END) AS "ASO_NE"
        ,COUNT(CASE WHEN (month IN (8, 9, 10) AND wind_direction = 'E') THEN 1 END) AS "ASO_E"
        ,COUNT(CASE WHEN (month IN (8, 9, 10) AND wind_direction = 'SE') THEN 1 END) AS "ASO_SE"
        ,COUNT(CASE WHEN (month IN (8, 9, 10) AND wind_direction = 'S') THEN 1 END) AS "ASO_S"
        ,COUNT(CASE WHEN (month IN (8, 9, 10) AND wind_direction = 'SW') THEN 1 END) AS "ASO_SW"
        ,COUNT(CASE WHEN (month IN (8, 9, 10) AND wind_direction = 'W') THEN 1 END) AS "ASO_W"
        ,COUNT(CASE WHEN (month IN (8, 9, 10) AND wind_direction = 'NW') THEN 1 END) AS "ASO_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (8, 9, 10)) AND (day IS NOT NULL)) THEN day END) AS "ASO_count"
        ,MAX(CASE
                WHEN ((month IN (8, 9, 10)) AND NOT (month = 8 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "ASO_max_day_diff"
        ,COUNT(CASE WHEN (month IN (9, 10, 11) AND wind_direction = 'N') THEN 1 END) AS "SON_N"
        ,COUNT(CASE WHEN (month IN (9, 10, 11) AND wind_direction = 'NE') THEN 1 END) AS "SON_NE"
        ,COUNT(CASE WHEN (month IN (9, 10, 11) AND wind_direction = 'E') THEN 1 END) AS "SON_E"
        ,COUNT(CASE WHEN (month IN (9, 10, 11) AND wind_direction = 'SE') THEN 1 END) AS "SON_SE"
        ,COUNT(CASE WHEN (month IN (9, 10, 11) AND wind_direction = 'S') THEN 1 END) AS "SON_S"
        ,COUNT(CASE WHEN (month IN (9, 10, 11) AND wind_direction = 'SW') THEN 1 END) AS "SON_SW"
        ,COUNT(CASE WHEN (month IN (9, 10, 11) AND wind_direction = 'W') THEN 1 END) AS "SON_W"
        ,COUNT(CASE WHEN (month IN (9, 10, 11) AND wind_direction = 'NW') THEN 1 END) AS "SON_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (9, 10, 11)) AND (day IS NOT NULL)) THEN day END) AS "SON_count"
        ,MAX(CASE
                WHEN ((month IN (9, 10, 11)) AND NOT (month = 9 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "SON_max_day_diff"
        ,COUNT(CASE WHEN (month IN (10, 11, 12) AND wind_direction = 'N') THEN 1 END) AS "OND_N"
        ,COUNT(CASE WHEN (month IN (10, 11, 12) AND wind_direction = 'NE') THEN 1 END) AS "OND_NE"
        ,COUNT(CASE WHEN (month IN (10, 11, 12) AND wind_direction = 'E') THEN 1 END) AS "OND_E"
        ,COUNT(CASE WHEN (month IN (10, 11, 12) AND wind_direction = 'SE') THEN 1 END) AS "OND_SE"
        ,COUNT(CASE WHEN (month IN (10, 11, 12) AND wind_direction = 'S') THEN 1 END) AS "OND_S"
        ,COUNT(CASE WHEN (month IN (10, 11, 12) AND wind_direction = 'SW') THEN 1 END) AS "OND_SW"
        ,COUNT(CASE WHEN (month IN (10, 11, 12) AND wind_direction = 'W') THEN 1 END) AS "OND_W"
        ,COUNT(CASE WHEN (month IN (10, 11, 12) AND wind_direction = 'NW') THEN 1 END) AS "OND_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (10, 11, 12)) AND (day IS NOT NULL)) THEN day END) AS "OND_count"
        ,MAX(CASE
                WHEN ((month IN (10, 11, 12)) AND NOT (month = 10 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "OND_max_day_diff"
        ,COUNT(CASE WHEN (month IN (11, 12, 13) AND wind_direction = 'N') THEN 1 END) AS "NDJ_N"
        ,COUNT(CASE WHEN (month IN (11, 12, 13) AND wind_direction = 'NE') THEN 1 END) AS "NDJ_NE"
        ,COUNT(CASE WHEN (month IN (11, 12, 13) AND wind_direction = 'E') THEN 1 END) AS "NDJ_E"
        ,COUNT(CASE WHEN (month IN (11, 12, 13) AND wind_direction = 'SE') THEN 1 END) AS "NDJ_SE"
        ,COUNT(CASE WHEN (month IN (11, 12, 13) AND wind_direction = 'S') THEN 1 END) AS "NDJ_S"
        ,COUNT(CASE WHEN (month IN (11, 12, 13) AND wind_direction = 'SW') THEN 1 END) AS "NDJ_SW"
        ,COUNT(CASE WHEN (month IN (11, 12, 13) AND wind_direction = 'W') THEN 1 END) AS "NDJ_W"
        ,COUNT(CASE WHEN (month IN (11, 12, 13) AND wind_direction = 'NW') THEN 1 END) AS "NDJ_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (11, 12, 13)) AND (day IS NOT NULL)) THEN day END) AS "NDJ_count"
        ,MAX(CASE
                WHEN ((month IN (11, 12, 13)) AND NOT (month = 11 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "NDJ_max_day_diff"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3, 4, 5) AND wind_direction = 'N') THEN 1 END) AS "DRY_N"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3, 4, 5) AND wind_direction = 'NE') THEN 1 END) AS "DRY_NE"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3, 4, 5) AND wind_direction = 'E') THEN 1 END) AS "DRY_E"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3, 4, 5) AND wind_direction = 'SE') THEN 1 END) AS "DRY_SE"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3, 4, 5) AND wind_direction = 'S') THEN 1 END) AS "DRY_S"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3, 4, 5) AND wind_direction = 'SW') THEN 1 END) AS "DRY_SW"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3, 4, 5) AND wind_direction = 'W') THEN 1 END) AS "DRY_W"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3, 4, 5) AND wind_direction = 'NW') THEN 1 END) AS "DRY_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (0, 1, 2, 3, 4, 5)) AND (day IS NOT NULL)) THEN day END) AS "DRY_count"
        ,MAX(CASE
                WHEN ((month IN (0, 1, 2, 3, 4, 5)) AND NOT (month = 0 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "DRY_max_day_diff"
        ,COUNT(CASE WHEN (month IN (6, 7, 8, 9, 10, 11) AND wind_direction = 'N') THEN 1 END) AS "WET_N"
        ,COUNT(CASE WHEN (month IN (6, 7, 8, 9, 10, 11) AND wind_direction = 'NE') THEN 1 END) AS "WET_NE"
        ,COUNT(CASE WHEN (month IN (6, 7, 8, 9, 10, 11) AND wind_direction = 'E') THEN 1 END) AS "WET_E"
        ,COUNT(CASE WHEN (month IN (6, 7, 8, 9, 10, 11) AND wind_direction = 'SE') THEN 1 END) AS "WET_SE"
        ,COUNT(CASE WHEN (month IN (6, 7, 8, 9, 10, 11) AND wind_direction = 'S') THEN 1 END) AS "WET_S"
        ,COUNT(CASE WHEN (month IN (6, 7, 8, 9, 10, 11) AND wind_direction = 'SW') THEN 1 END) AS "WET_SW"
        ,COUNT(CASE WHEN (month IN (6, 7, 8, 9, 10, 11) AND wind_direction = 'W') THEN 1 END) AS "WET_W"
        ,COUNT(CASE WHEN (month IN (6, 7, 8, 9, 10, 11) AND wind_direction = 'NW') THEN 1 END) AS "WET_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (6, 7, 8, 9, 10, 11)) AND (day IS NOT NULL)) THEN day END) AS "WET_count"
        ,MAX(CASE
                WHEN ((month IN (6, 7, 8, 9, 10, 11)) AND NOT (month = 6 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "WET_max_day_diff"
        ,COUNT(CASE WHEN (month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 112) AND wind_direction = 'N') THEN 1 END) AS "ANNUAL_N"
        ,COUNT(CASE WHEN (month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 112) AND wind_direction = 'NE') THEN 1 END) AS "ANNUAL_NE"
        ,COUNT(CASE WHEN (month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 112) AND wind_direction = 'E') THEN 1 END) AS "ANNUAL_E"
        ,COUNT(CASE WHEN (month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 112) AND wind_direction = 'SE') THEN 1 END) AS "ANNUAL_SE"
        ,COUNT(CASE WHEN (month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 112) AND wind_direction = 'S') THEN 1 END) AS "ANNUAL_S"
        ,COUNT(CASE WHEN (month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 112) AND wind_direction = 'SW') THEN 1 END) AS "ANNUAL_SW"
        ,COUNT(CASE WHEN (month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 112) AND wind_direction = 'W') THEN 1 END) AS "ANNUAL_W"
        ,COUNT(CASE WHEN (month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 112) AND wind_direction = 'NW') THEN 1 END) AS "ANNUAL_NW"
        ,COUNT(DISTINCT CASE WHEN ((month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)) AND (day IS NOT NULL)) THEN day END) AS "ANNUAL_count"
        ,MAX(CASE
                WHEN ((month IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)) AND NOT (month = 1 AND EXTRACT(DAY FROM day) <= ({{max_day_gap}}+1))) THEN day_diff
                ELSE NULL
            END
        ) AS "ANNUAL_max_day_diff"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3) AND wind_direction = 'N') THEN 1 END) AS "DJFM_N"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3) AND wind_direction = 'NE') THEN 1 END) AS "DJFM_NE"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3) AND wind_direction = 'E') THEN 1 END) AS "DJFM_E"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3) AND wind_direction = 'SE') THEN 1 END) AS "DJFM_SE"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3) AND wind_direction = 'S') THEN 1 END) AS "DJFM_S"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3) AND wind_direction = 'SW') THEN 1 END) AS "DJFM_SW"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3) AND wind_direction = 'W') THEN 1 END) AS "DJFM_W"
        ,COUNT(CASE WHEN (month IN (0, 1, 2, 3) AND wind_direction = 'NW') THEN 1 END) AS "DJFM_NW"
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
        ,CASE WHEN "JFM_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"JFM_N"::numeric)/"JFM_count"::numeric,2) || '/' ||
                ROUND((100*"JFM_NE"::numeric)/"JFM_count"::numeric,2) || '/' ||
                ROUND((100*"JFM_E"::numeric)/"JFM_count"::numeric,2) || '/' ||
                ROUND((100*"JFM_SE"::numeric)/"JFM_count"::numeric,2) || '/' ||
                ROUND((100*"JFM_S"::numeric)/"JFM_count"::numeric,2) || '/' ||
                ROUND((100*"JFM_SW"::numeric)/"JFM_count"::numeric,2) || '/' ||
                ROUND((100*"JFM_W"::numeric)/"JFM_count"::numeric,2) || '/' ||
                ROUND((100*"JFM_NW"::numeric)/"JFM_count"::numeric,2)
            ELSE NULL END AS "JFM"
        ,ROUND(((100*(CASE WHEN "JFM_max_day_diff" <= ({{max_day_gap}}+1) THEN "JFM_count" ELSE 0 END))::numeric/"JFM_total"::numeric),2) AS "JFM (% of days)"
        ,CASE WHEN "FMA_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"FMA_N"::numeric)/"FMA_count"::numeric,2) || '/' ||
                ROUND((100*"FMA_NE"::numeric)/"FMA_count"::numeric,2) || '/' ||
                ROUND((100*"FMA_E"::numeric)/"FMA_count"::numeric,2) || '/' ||
                ROUND((100*"FMA_SE"::numeric)/"FMA_count"::numeric,2) || '/' ||
                ROUND((100*"FMA_S"::numeric)/"FMA_count"::numeric,2) || '/' ||
                ROUND((100*"FMA_SW"::numeric)/"FMA_count"::numeric,2) || '/' ||
                ROUND((100*"FMA_W"::numeric)/"FMA_count"::numeric,2) || '/' ||
                ROUND((100*"FMA_NW"::numeric)/"FMA_count"::numeric,2)
            ELSE NULL END AS "FMA"
        ,ROUND(((100*(CASE WHEN "FMA_max_day_diff" <= ({{max_day_gap}}+1) THEN "FMA_count" ELSE 0 END))::numeric/"FMA_total"::numeric),2) AS "FMA (% of days)"
        ,CASE WHEN "MAM_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"MAM_N"::numeric)/"MAM_count"::numeric,2) || '/' ||
                ROUND((100*"MAM_NE"::numeric)/"MAM_count"::numeric,2) || '/' ||
                ROUND((100*"MAM_E"::numeric)/"MAM_count"::numeric,2) || '/' ||
                ROUND((100*"MAM_SE"::numeric)/"MAM_count"::numeric,2) || '/' ||
                ROUND((100*"MAM_S"::numeric)/"MAM_count"::numeric,2) || '/' ||
                ROUND((100*"MAM_SW"::numeric)/"MAM_count"::numeric,2) || '/' ||
                ROUND((100*"MAM_W"::numeric)/"MAM_count"::numeric,2) || '/' ||
                ROUND((100*"MAM_NW"::numeric)/"MAM_count"::numeric,2)
            ELSE NULL END AS "MAM"
        ,ROUND(((100*(CASE WHEN "MAM_max_day_diff" <= ({{max_day_gap}}+1) THEN "MAM_count" ELSE 0 END))::numeric/"MAM_total"::numeric),2) AS "MAM (% of days)"
        ,CASE WHEN "AMJ_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"AMJ_N"::numeric)/"AMJ_count"::numeric,2) || '/' ||
                ROUND((100*"AMJ_NE"::numeric)/"AMJ_count"::numeric,2) || '/' ||
                ROUND((100*"AMJ_E"::numeric)/"AMJ_count"::numeric,2) || '/' ||
                ROUND((100*"AMJ_SE"::numeric)/"AMJ_count"::numeric,2) || '/' ||
                ROUND((100*"AMJ_S"::numeric)/"AMJ_count"::numeric,2) || '/' ||
                ROUND((100*"AMJ_SW"::numeric)/"AMJ_count"::numeric,2) || '/' ||
                ROUND((100*"AMJ_W"::numeric)/"AMJ_count"::numeric,2) || '/' ||
                ROUND((100*"AMJ_NW"::numeric)/"AMJ_count"::numeric,2)
            ELSE NULL END AS "AMJ"
        ,ROUND(((100*(CASE WHEN "AMJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "AMJ_count" ELSE 0 END))::numeric/"AMJ_total"::numeric),2) AS "AMJ (% of days)"
        ,CASE WHEN "MJJ_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"MJJ_N"::numeric)/"MJJ_count"::numeric,2) || '/' ||
                ROUND((100*"MJJ_NE"::numeric)/"MJJ_count"::numeric,2) || '/' ||
                ROUND((100*"MJJ_E"::numeric)/"MJJ_count"::numeric,2) || '/' ||
                ROUND((100*"MJJ_SE"::numeric)/"MJJ_count"::numeric,2) || '/' ||
                ROUND((100*"MJJ_S"::numeric)/"MJJ_count"::numeric,2) || '/' ||
                ROUND((100*"MJJ_SW"::numeric)/"MJJ_count"::numeric,2) || '/' ||
                ROUND((100*"MJJ_W"::numeric)/"MJJ_count"::numeric,2) || '/' ||
                ROUND((100*"MJJ_NW"::numeric)/"MJJ_count"::numeric,2)
            ELSE NULL END AS "MJJ"
        ,ROUND(((100*(CASE WHEN "MJJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "MJJ_count" ELSE 0 END))::numeric/"MJJ_total"::numeric),2) AS "MJJ (% of days)"
        ,CASE WHEN "JJA_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"JJA_N"::numeric)/"JJA_count"::numeric,2) || '/' ||
                ROUND((100*"JJA_NE"::numeric)/"JJA_count"::numeric,2) || '/' ||
                ROUND((100*"JJA_E"::numeric)/"JJA_count"::numeric,2) || '/' ||
                ROUND((100*"JJA_SE"::numeric)/"JJA_count"::numeric,2) || '/' ||
                ROUND((100*"JJA_S"::numeric)/"JJA_count"::numeric,2) || '/' ||
                ROUND((100*"JJA_SW"::numeric)/"JJA_count"::numeric,2) || '/' ||
                ROUND((100*"JJA_W"::numeric)/"JJA_count"::numeric,2) || '/' ||
                ROUND((100*"JJA_NW"::numeric)/"JJA_count"::numeric,2)
            ELSE NULL END AS "JJA"
        ,ROUND(((100*(CASE WHEN "JJA_max_day_diff" <= ({{max_day_gap}}+1) THEN "JJA_count" ELSE 0 END))::numeric/"JJA_total"::numeric),2) AS "JJA (% of days)"
        ,CASE WHEN "JAS_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"JAS_N"::numeric)/"JAS_count"::numeric,2) || '/' ||
                ROUND((100*"JAS_NE"::numeric)/"JAS_count"::numeric,2) || '/' ||
                ROUND((100*"JAS_E"::numeric)/"JAS_count"::numeric,2) || '/' ||
                ROUND((100*"JAS_SE"::numeric)/"JAS_count"::numeric,2) || '/' ||
                ROUND((100*"JAS_S"::numeric)/"JAS_count"::numeric,2) || '/' ||
                ROUND((100*"JAS_SW"::numeric)/"JAS_count"::numeric,2) || '/' ||
                ROUND((100*"JAS_W"::numeric)/"JAS_count"::numeric,2) || '/' ||
                ROUND((100*"JAS_NW"::numeric)/"JAS_count"::numeric,2)
            ELSE NULL END AS "JAS"
        ,ROUND(((100*(CASE WHEN "JAS_max_day_diff" <= ({{max_day_gap}}+1) THEN "JAS_count" ELSE 0 END))::numeric/"JAS_total"::numeric),2) AS "JAS (% of days)"
        ,CASE WHEN "ASO_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"ASO_N"::numeric)/"ASO_count"::numeric,2) || '/' ||
                ROUND((100*"ASO_NE"::numeric)/"ASO_count"::numeric,2) || '/' ||
                ROUND((100*"ASO_E"::numeric)/"ASO_count"::numeric,2) || '/' ||
                ROUND((100*"ASO_SE"::numeric)/"ASO_count"::numeric,2) || '/' ||
                ROUND((100*"ASO_S"::numeric)/"ASO_count"::numeric,2) || '/' ||
                ROUND((100*"ASO_SW"::numeric)/"ASO_count"::numeric,2) || '/' ||
                ROUND((100*"ASO_W"::numeric)/"ASO_count"::numeric,2) || '/' ||
                ROUND((100*"ASO_NW"::numeric)/"ASO_count"::numeric,2)
            ELSE NULL END AS "ASO"
        ,ROUND(((100*(CASE WHEN "ASO_max_day_diff" <= ({{max_day_gap}}+1) THEN "ASO_count" ELSE 0 END))::numeric/"ASO_total"::numeric),2) AS "ASO (% of days)"
        ,CASE WHEN "SON_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"SON_N"::numeric)/"SON_count"::numeric,2) || '/' ||
                ROUND((100*"SON_NE"::numeric)/"SON_count"::numeric,2) || '/' ||
                ROUND((100*"SON_E"::numeric)/"SON_count"::numeric,2) || '/' ||
                ROUND((100*"SON_SE"::numeric)/"SON_count"::numeric,2) || '/' ||
                ROUND((100*"SON_S"::numeric)/"SON_count"::numeric,2) || '/' ||
                ROUND((100*"SON_SW"::numeric)/"SON_count"::numeric,2) || '/' ||
                ROUND((100*"SON_W"::numeric)/"SON_count"::numeric,2) || '/' ||
                ROUND((100*"SON_NW"::numeric)/"SON_count"::numeric,2)
            ELSE NULL END AS "SON"
        ,ROUND(((100*(CASE WHEN "SON_max_day_diff" <= ({{max_day_gap}}+1) THEN "SON_count" ELSE 0 END))::numeric/"SON_total"::numeric),2) AS "SON (% of days)"
        ,CASE WHEN "OND_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"OND_N"::numeric)/"OND_count"::numeric,2) || '/' ||
                ROUND((100*"OND_NE"::numeric)/"OND_count"::numeric,2) || '/' ||
                ROUND((100*"OND_E"::numeric)/"OND_count"::numeric,2) || '/' ||
                ROUND((100*"OND_SE"::numeric)/"OND_count"::numeric,2) || '/' ||
                ROUND((100*"OND_S"::numeric)/"OND_count"::numeric,2) || '/' ||
                ROUND((100*"OND_SW"::numeric)/"OND_count"::numeric,2) || '/' ||
                ROUND((100*"OND_W"::numeric)/"OND_count"::numeric,2) || '/' ||
                ROUND((100*"OND_NW"::numeric)/"OND_count"::numeric,2)
            ELSE NULL END AS "OND"
        ,ROUND(((100*(CASE WHEN "OND_max_day_diff" <= ({{max_day_gap}}+1) THEN "OND_count" ELSE 0 END))::numeric/"OND_total"::numeric),2) AS "OND (% of days)"
        ,CASE WHEN "NDJ_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"NDJ_N"::numeric)/"NDJ_count"::numeric,2) || '/' ||
                ROUND((100*"NDJ_NE"::numeric)/"NDJ_count"::numeric,2) || '/' ||
                ROUND((100*"NDJ_E"::numeric)/"NDJ_count"::numeric,2) || '/' ||
                ROUND((100*"NDJ_SE"::numeric)/"NDJ_count"::numeric,2) || '/' ||
                ROUND((100*"NDJ_S"::numeric)/"NDJ_count"::numeric,2) || '/' ||
                ROUND((100*"NDJ_SW"::numeric)/"NDJ_count"::numeric,2) || '/' ||
                ROUND((100*"NDJ_W"::numeric)/"NDJ_count"::numeric,2) || '/' ||
                ROUND((100*"NDJ_NW"::numeric)/"NDJ_count"::numeric,2)
            ELSE NULL END AS "NDJ"
        ,ROUND(((100*(CASE WHEN "NDJ_max_day_diff" <= ({{max_day_gap}}+1) THEN "NDJ_count" ELSE 0 END))::numeric/"NDJ_total"::numeric),2) AS "NDJ (% of days)"
        ,CASE WHEN "DRY_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"DRY_N"::numeric)/"DRY_count"::numeric,2) || '/' ||
                ROUND((100*"DRY_NE"::numeric)/"DRY_count"::numeric,2) || '/' ||
                ROUND((100*"DRY_E"::numeric)/"DRY_count"::numeric,2) || '/' ||
                ROUND((100*"DRY_SE"::numeric)/"DRY_count"::numeric,2) || '/' ||
                ROUND((100*"DRY_S"::numeric)/"DRY_count"::numeric,2) || '/' ||
                ROUND((100*"DRY_SW"::numeric)/"DRY_count"::numeric,2) || '/' ||
                ROUND((100*"DRY_W"::numeric)/"DRY_count"::numeric,2) || '/' ||
                ROUND((100*"DRY_NW"::numeric)/"DRY_count"::numeric,2)
            ELSE NULL END AS "DRY"
        ,ROUND(((100*(CASE WHEN "DRY_max_day_diff" <= ({{max_day_gap}}+1) THEN "DRY_count" ELSE 0 END))::numeric/"DRY_total"::numeric),2) AS "DRY (% of days)"
        ,CASE WHEN "WET_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"WET_N"::numeric)/"WET_count"::numeric,2) || '/' ||
                ROUND((100*"WET_NE"::numeric)/"WET_count"::numeric,2) || '/' ||
                ROUND((100*"WET_E"::numeric)/"WET_count"::numeric,2) || '/' ||
                ROUND((100*"WET_SE"::numeric)/"WET_count"::numeric,2) || '/' ||
                ROUND((100*"WET_S"::numeric)/"WET_count"::numeric,2) || '/' ||
                ROUND((100*"WET_SW"::numeric)/"WET_count"::numeric,2) || '/' ||
                ROUND((100*"WET_W"::numeric)/"WET_count"::numeric,2) || '/' ||
                ROUND((100*"WET_NW"::numeric)/"WET_count"::numeric,2)
            ELSE NULL END AS "WET"
        ,ROUND(((100*(CASE WHEN "WET_max_day_diff" <= ({{max_day_gap}}+1) THEN "WET_count" ELSE 0 END))::numeric/"WET_total"::numeric),2) AS "WET (% of days)"
        ,CASE WHEN "ANNUAL_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"ANNUAL_N"::numeric)/"ANNUAL_count"::numeric,2) || '/' ||
                ROUND((100*"ANNUAL_NE"::numeric)/"ANNUAL_count"::numeric,2) || '/' ||
                ROUND((100*"ANNUAL_E"::numeric)/"ANNUAL_count"::numeric,2) || '/' ||
                ROUND((100*"ANNUAL_SE"::numeric)/"ANNUAL_count"::numeric,2) || '/' ||
                ROUND((100*"ANNUAL_S"::numeric)/"ANNUAL_count"::numeric,2) || '/' ||
                ROUND((100*"ANNUAL_SW"::numeric)/"ANNUAL_count"::numeric,2) || '/' ||
                ROUND((100*"ANNUAL_W"::numeric)/"ANNUAL_count"::numeric,2) || '/' ||
                ROUND((100*"ANNUAL_NW"::numeric)/"ANNUAL_count"::numeric,2)
            ELSE NULL END AS "ANNUAL"
        ,ROUND(((100*(CASE WHEN "ANNUAL_max_day_diff" <= ({{max_day_gap}}+1) THEN "ANNUAL_count" ELSE 0 END))::numeric/"ANNUAL_total"::numeric),2) AS "ANNUAL (% of days)"
        ,CASE WHEN "DJFM_max_day_diff" <= ({{max_day_gap}}+1) 
            THEN 
                ROUND((100*"DJFM_N"::numeric)/"DJFM_count"::numeric,2) || '/' ||
                ROUND((100*"DJFM_NE"::numeric)/"DJFM_count"::numeric,2) || '/' ||
                ROUND((100*"DJFM_E"::numeric)/"DJFM_count"::numeric,2) || '/' ||
                ROUND((100*"DJFM_SE"::numeric)/"DJFM_count"::numeric,2) || '/' ||
                ROUND((100*"DJFM_S"::numeric)/"DJFM_count"::numeric,2) || '/' ||
                ROUND((100*"DJFM_SW"::numeric)/"DJFM_count"::numeric,2) || '/' ||
                ROUND((100*"DJFM_W"::numeric)/"DJFM_count"::numeric,2) || '/' ||
                ROUND((100*"DJFM_NW"::numeric)/"DJFM_count"::numeric,2)
            ELSE NULL END AS "DJFM"
        ,ROUND(((100*(CASE WHEN "DJFM_max_day_diff" <= ({{max_day_gap}}+1) THEN "DJFM_count" ELSE 0 END))::numeric/"DJFM_total"::numeric),2) AS "DJFM (% of days)"
    FROM aggreated_data ad
    LEFT JOIN aggreation_total_days atd ON atd.year=ad.year
)
SELECT
    station
    ,year
    ,CASE WHEN "JFM (% of days)" >= (100-{{max_day_pct}}) THEN "JFM" ELSE NULL END AS "JFM (N/NE/E/SE/S/SW/W/NW)"
    ,"JFM (% of days)" 
    ,CASE WHEN "FMA (% of days)" >= (100-{{max_day_pct}}) THEN "FMA" ELSE NULL END AS "FMA (N/NE/E/SE/S/SW/W/NW)"
    ,"FMA (% of days)"
    ,CASE WHEN "MAM (% of days)" >= (100-{{max_day_pct}}) THEN "MAM" ELSE NULL END AS "MAM (N/NE/E/SE/S/SW/W/NW)"
    ,"MAM (% of days)"
    ,CASE WHEN "AMJ (% of days)" >= (100-{{max_day_pct}}) THEN "AMJ" ELSE NULL END AS "AMJ (N/NE/E/SE/S/SW/W/NW)"
    ,"AMJ (% of days)"
    ,CASE WHEN "MJJ (% of days)" >= (100-{{max_day_pct}}) THEN "MJJ" ELSE NULL END AS "MJJ (N/NE/E/SE/S/SW/W/NW)"
    ,"MJJ (% of days)"
    ,CASE WHEN "JJA (% of days)" >= (100-{{max_day_pct}}) THEN "JJA" ELSE NULL END AS "JJA (N/NE/E/SE/S/SW/W/NW)"
    ,"JJA (% of days)"
    ,CASE WHEN "JAS (% of days)" >= (100-{{max_day_pct}}) THEN "JAS" ELSE NULL END AS "JAS (N/NE/E/SE/S/SW/W/NW)"
    ,"JAS (% of days)"
    ,CASE WHEN "ASO (% of days)" >= (100-{{max_day_pct}}) THEN "ASO" ELSE NULL END AS "ASO (N/NE/E/SE/S/SW/W/NW)"
    ,"ASO (% of days)"
    ,CASE WHEN "SON (% of days)" >= (100-{{max_day_pct}}) THEN "SON" ELSE NULL END AS "SON (N/NE/E/SE/S/SW/W/NW)"
    ,"SON (% of days)"
    ,CASE WHEN "OND (% of days)" >= (100-{{max_day_pct}}) THEN "OND" ELSE NULL END AS "OND (N/NE/E/SE/S/SW/W/NW)"
    ,"OND (% of days)"
    ,CASE WHEN "NDJ (% of days)" >= (100-{{max_day_pct}}) THEN "NDJ" ELSE NULL END AS "NDJ (N/NE/E/SE/S/SW/W/NW)"
    ,"NDJ (% of days)"
    ,CASE WHEN "DRY (% of days)" >= (100-{{max_day_pct}}) THEN "DRY" ELSE NULL END AS "DRY (N/NE/E/SE/S/SW/W/NW)"
    ,"DRY (% of days)"
    ,CASE WHEN "WET (% of days)" >= (100-{{max_day_pct}}) THEN "WET" ELSE NULL END AS "WET (N/NE/E/SE/S/SW/W/NW)"
    ,"WET (% of days)"
    ,CASE WHEN "ANNUAL (% of days)" >= (100-{{max_day_pct}}) THEN "ANNUAL" ELSE NULL END AS "ANNUAL (N/NE/E/SE/S/SW/W/NW)"
    ,"ANNUAL (% of days)"
    ,CASE WHEN "DJFM (% of days)" >= (100-{{max_day_pct}}) THEN "DJFM" ELSE NULL END AS "DJFM (N/NE/E/SE/S/SW/W/NW)"
    ,"DJFM (% of days)"
FROM aggregation_pct
ORDER BY year