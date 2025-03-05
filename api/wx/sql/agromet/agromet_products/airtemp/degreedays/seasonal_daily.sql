WITH agg_definitions AS (
    SELECT *
    FROM (VALUES
        ('JFM', ARRAY[1, 2, 3]),
        ('FMA', ARRAY[2, 3, 4]),
        ('MAM', ARRAY[3, 4, 5]),
        ('AMJ', ARRAY[4, 5, 6]),
        ('MJJ', ARRAY[5, 6, 7]),
        ('JJA', ARRAY[6, 7, 8]),
        ('JAS', ARRAY[7, 8, 9]),
        ('ASO', ARRAY[8, 9, 10]),
        ('SON', ARRAY[9, 10, 11]),
        ('OND', ARRAY[10, 11, 12]),
        ('NDJ', ARRAY[11, 12, 13]),
        ('DRY', ARRAY[0, 1, 2, 3, 4, 5]),
        ('WET', ARRAY[6, 7, 8, 9, 10, 11]),
        ('ANNUAL', ARRAY[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
        ('DJFM', ARRAY[0, 1, 2, 3])
    ) AS t(agg, months)
)
,filtered_data AS (
    SELECT
        ds.station_id 
        ,ds.variable_id 
        ,EXTRACT(MONTH FROM ds.day) AS month
        ,EXTRACT(YEAR FROM ds.day) AS year
        ,so.symbol AS sampling_operation
        ,(ds.max_value+ds.min_value)/2-30 AS value
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    JOIN wx_samplingoperation so ON so.id = vr.sampling_operation_id           
    WHERE ds.station_id = 4
    AND ds.variable_id = 10
    AND ds.day >= '2023-12-01'
    AND ds.day < '2026-02-01'
),
extended_data AS(
    SELECT
        station_id
        ,variable_id
        ,CASE 
            WHEN month=12 THEN 0
            WHEN month=1 THEN 13
        END as month    
        ,CASE 
            WHEN month=12 THEN year+1
            WHEN month=1 THEN year-1
        END as year
        ,sampling_operation
        ,value       
    FROM filtered_data
    WHERE month in (1,12)
    UNION ALL
    SELECT
        *
    FROM filtered_data
)
SELECT 
    st.name AS station
    ,ed.variable_id
    ,ed.year
    ,ad.agg
    ,ROUND(
        SUM(
            CASE
                WHEN value > 0 THEN value
                ELSE 0
            END
        )::NUMERIC, 2
    ) AS value
FROM extended_data ed
JOIN wx_station st ON st.id = ed.station_id
CROSS JOIN  agg_definitions ad
WHERE ed.month = ANY(ad.months)
AND year BETWEEN 2024 AND 2025
GROUP BY st.name, ed.variable_id, ed.year, ad.agg, ed.sampling_operation
ORDER BY year
