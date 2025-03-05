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
        ,CASE so.symbol
            WHEN 'MIN' THEN ds.min_value
            WHEN 'MAX' THEN ds.max_value
            WHEN 'ACCUM' THEN ds.sum_value
                ELSE ds.avg_value
        END AS value
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    JOIN wx_samplingoperation so ON so.id = vr.sampling_operation_id           
    WHERE ds.station_id = 4
    AND ds.variable_id IN (0,10,30)
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
    st.name AS station, 
    ed.variable_id, 
    ed.year, 
    ad.agg
    ,ROUND(
    CASE ed.sampling_operation
        WHEN 'MIN' THEN MIN(value)::numeric
        WHEN 'MAX' THEN MAX(value)::numeric
        WHEN 'ACCUM' THEN SUM(value)::numeric
        WHEN 'STDV' THEN STDDEV(value)::numeric
        WHEN 'RMS' THEN SQRT(AVG(POW(value, 2)))::numeric
        ELSE AVG(value)::numeric
    END, 2
    ) AS value
FROM extended_data ed
JOIN wx_station st ON st.id = ed.station_id
CROSS JOIN  agg_definitions ad
WHERE ed.month = ANY(ad.months)
AND year BETWEEN 2024 AND 2025
GROUP BY st.name, ed.variable_id, ed.year, ad.agg, ed.sampling_operation
ORDER BY year
