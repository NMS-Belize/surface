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
,aggregation_total_days AS(
    SELECT
        SUM(days_in_month) FILTER(WHERE month IN ({{aggregation_months}})) AS "total_days"
    FROM extended_month_days
    WHERE year BETWEEN {{start_year}} AND {{end_year}}  
)
,daily_data AS (
    SELECT
        station_id
        ,day
        ,EXTRACT(DAY FROM day) AS day_of_month
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,MIN(CASE vr.symbol WHEN 'WNDDIR' THEN avg_value END) AS wnd_dir
        ,MIN(CASE vr.symbol WHEN 'WNDSPD' THEN avg_value END) AS wnd_spd
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{station_id}}
      AND vr.symbol in ('WNDDIR', 'WNDSPD')
      AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
    GROUP BY station_id, day
)
,discretized_data AS (
    SELECT
        station_id
        ,day
        ,day_of_month
        ,month
        ,year
        ,CASE
            WHEN wnd_spd = 0 THEN '-'
            ELSE CASE
                WHEN (wnd_dir BETWEEN 337.5 AND 360) OR (wnd_dir BETWEEN 0 AND 22.5) THEN 'N'
                WHEN wnd_dir BETWEEN 22.5 AND 67.5 THEN 'NE'
                WHEN wnd_dir BETWEEN 67.5 AND 112.5 THEN 'E'
                WHEN wnd_dir BETWEEN 112.5 AND 157.5 THEN 'SE'
                WHEN wnd_dir BETWEEN 157.5 AND 202.5 THEN 'S'
                WHEN wnd_dir BETWEEN 202.5 AND 247.5 THEN 'SW'
                WHEN wnd_dir BETWEEN 247.5 AND 292.5 THEN 'W'
                WHEN wnd_dir BETWEEN 292.5 AND 337.5 THEN 'NW'
            END
        END AS wnd_dir
        ,CASE
            WHEN wnd_spd = 0 THEN '0 kt' 
            WHEN wnd_spd > 0 AND wnd_spd <= 5 THEN '0-5 kt'
            WHEN wnd_spd > 5 AND wnd_spd <= 10 THEN '5-10 kt'
            WHEN wnd_spd > 10 AND wnd_spd <= 15 THEN '10-15 kt'
            WHEN wnd_spd > 15 AND wnd_spd <= 20 THEN '15-20 kt'
            WHEN wnd_spd > 20 AND wnd_spd <= 25 THEN '20-25 kt'
            WHEN wnd_spd > 25 THEN '25+ kt'
        END AS wnd_spd    
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
        ,wnd_dir
        ,wnd_spd
    FROM discretized_data
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM discretized_data
)
,daily_lagged_data AS (
    SELECT
        *
        ,day - 1 - LAG(day) OVER (ORDER BY day) AS day_gap
    FROM extended_data
    WHERE year BETWEEN {{start_year}} AND {{end_year}}  
      AND month in ({{aggregation_months}})
)
,data_stats AS (
    SELECT
        station_id
        ,day_count
        ,total_days
        ,ROUND((100*day_count::numeric)/total_days::numeric,2) AS day_pct
        ,max_day_gap
    FROM (
        SELECT
            station_id
            ,COUNT(DISTINCT day) FILTER(WHERE day IS NOT NULL) AS day_count
            ,MAX(day_gap) FILTER(
                WHERE NOT (
                   day_of_month <= {{max_day_gap}} AND month = (SELECT MIN(month) FROM UNNEST(ARRAY[{{aggregation_months}}]) AS month)
                )
            ) AS "max_day_gap"
        FROM daily_lagged_data
        GROUP BY station_id
    ) AS t
    CROSS JOIN aggregation_total_days
),aggreated_data AS (
    SELECT
        station_id
        ,wnd_spd
        ,wnd_dir
        ,COUNT(*) AS count
    FROM daily_lagged_data dld
    WHERE wnd_dir != '-'
    GROUP BY station_id, wnd_spd, wnd_dir
)
,wind_coordinates AS (
    SELECT 
        {{station_id}} AS station_id,
        wsc.value AS wnd_spd,
        wdc.value AS wnd_dir
    FROM (VALUES ('0-5 kt'), ('5-10 kt'), ('10-15 kt'), ('15-20 kt'), ('20-25 kt'), ('25+ kt')) AS wsc(value)
    CROSS JOIN (VALUES ('N'), ('NE'), ('E'), ('SE'), ('S'), ('SW'), ('W'), ('NW')) AS wdc(value)
)
SELECT
    st.name AS station,
    'WIND ROSE' AS product,
    wc.wnd_spd AS "Wind Speed",
    wc.wnd_dir AS "Wind Direction",
    CASE 
        WHEN max_day_gap > {{max_day_gap}} OR day_pct < (100-{{max_day_pct}}) THEN NULL
        ELSE CASE
            WHEN count IS NULL THEN 0
            ELSE ROUND(100 * (count / SUM(count) OVER (PARTITION BY ad.station_id)), 3)
        END
    END AS "Frequency"
FROM wind_coordinates wc
JOIN wx_station st ON st.id = wc.station_id
LEFT JOIN aggreated_data ad 
    ON wc.station_id = ad.station_id
    AND wc.wnd_spd = ad.wnd_spd
    AND wc.wnd_dir = ad.wnd_dir
LEFT JOIN data_stats ds ON ds.station_id = ad.station_id
ORDER BY  station, "Wind Speed", "Wind Direction"
