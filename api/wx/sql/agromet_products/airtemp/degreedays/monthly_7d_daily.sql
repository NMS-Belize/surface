WITH filtered_data AS (
    SELECT
        EXTRACT(YEAR FROM ds.day) as year
        ,EXTRACT(MONTH FROM ds.day) as month
        ,ds.station_id
        ,ds.variable_id
        ,st.name AS station
        ,so.symbol AS sampling_operation
        ,CASE so.symbol
            WHEN 'MIN' THEN ds.min_value
            WHEN 'MAX' THEN ds.max_value
            WHEN 'ACCUM' THEN ds.sum_value
            ELSE ds.avg_value
        END as value
        ,CASE
            WHEN EXTRACT(DAY FROM ds.day) BETWEEN 1 AND 7 THEN 'agg_1'
            WHEN EXTRACT(DAY FROM ds.day) BETWEEN 8 AND 14 THEN 'agg_2'
            WHEN EXTRACT(DAY FROM ds.day) BETWEEN 15 AND 21 THEN 'agg_3'
            WHEN EXTRACT(DAY FROM ds.day) >= 22 THEN 'agg_4'
        END AS agg
    FROM daily_summary ds
    JOIN wx_station st ON st.id = ds.station_id
    JOIN wx_variable vr ON vr.id = ds.variable_id
    JOIN wx_samplingoperation so ON so.id = vr.sampling_operation_id   
    WHERE ds.day >= '2024-01-01'
        AND ds.day < '2025-01-01'
        AND ds.station_id = 4
        AND ds.variable_id IN (0,10,30)
        AND EXTRACT(MONTH FROM ds.day) IN (1,2)                                             
)
SELECT
    station
    ,variable_id
    ,year
    ,month
    ,agg
    ,ROUND(
        CASE sampling_operation
            WHEN 'MIN' THEN MIN(value)::numeric
            WHEN 'MAX' THEN MAX(value)::numeric
            WHEN 'STDV' THEN STDDEV(value)::numeric
            WHEN 'ACCUM' THEN SUM(value)::numeric
            WHEN 'RMS' THEN SQRT(AVG(POW(value, 2)))::numeric
            ELSE AVG(value)::numeric
        END, 2
    ) AS value
FROM filtered_data
GROUP BY station, variable_id, month, year, agg, sampling_operation
ORDER BY year, month