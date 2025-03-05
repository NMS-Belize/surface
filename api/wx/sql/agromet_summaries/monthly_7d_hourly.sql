WITH filtered_data AS (
    SELECT
        EXTRACT(YEAR FROM hs.datetime AT TIME ZONE 'America/Belize') as year
        ,EXTRACT(MONTH FROM hs.datetime AT TIME ZONE 'America/Belize') as month
        ,hs.station_id
        ,hs.variable_id
        ,st.name AS station
        ,so.symbol AS sampling_operation
        ,CASE so.symbol
            WHEN 'MIN' THEN hs.min_value
            WHEN 'MAX' THEN hs.max_value
            WHEN 'ACCUM' THEN hs.sum_value
            ELSE hs.avg_value
        END as value
        ,CASE
            WHEN EXTRACT(DAY FROM datetime AT TIME ZONE 'America/Belize') BETWEEN 1 AND 7 THEN 'agg_1'
            WHEN EXTRACT(DAY FROM datetime AT TIME ZONE 'America/Belize') BETWEEN 8 AND 14 THEN 'agg_2'
            WHEN EXTRACT(DAY FROM datetime AT TIME ZONE 'America/Belize') BETWEEN 15 AND 21 THEN 'agg_3'
            WHEN EXTRACT(DAY FROM datetime AT TIME ZONE 'America/Belize') >= 22 THEN 'agg_4'
        END AS agg
    FROM hourly_summary hs
    JOIN wx_station st ON st.id = hs.station_id
    JOIN wx_variable vr ON vr.id = hs.variable_id
    JOIN wx_samplingoperation so ON so.id = vr.sampling_operation_id   
    WHERE datetime AT TIME ZONE 'America/Belize' >= '2024-01-01'
        AND datetime AT TIME ZONE 'America/Belize' < '2025-01-01'
        AND station_id = 4
        AND variable_id IN (0,10,30)
        AND EXTRACT(MONTH FROM datetime AT TIME ZONE 'America/Belize') IN (1,2)                                             
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