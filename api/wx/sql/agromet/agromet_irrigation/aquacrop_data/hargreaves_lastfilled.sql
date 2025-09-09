WITH requested_entries AS (
    SELECT 
        day
        ,vr_symbol
    FROM (SELECT generate_series('{{ sim_start_date }}'::date, '{{ sim_end_date }}'::date, '1 DAY'::interval)::date AS day) AS days
    CROSS JOIN (VALUES ('TEMPMAX'), ('TEMPMIN'), ('PRECIP')) AS variable_symbols(vr_symbol)
)
,extended_daily_summary AS (
    SELECT
        COALESCE(re.day, ds.day) AS day
        ,COALESCE(re.vr_symbol, ds.vr_symbol) AS vr_symbol
        ,ds.min_value
        ,ds.max_value
        ,ds.avg_value
    FROM requested_entries re
    FULL OUTER JOIN (
        SELECT 
            *
            ,vr.symbol AS vr_symbol        
        FROM daily_summary ds
        JOIN wx_variable vr ON vr.id = ds.variable_id
        WHERE station_id = {{ station_id }}
          AND vr.symbol IN ('TEMPMAX', 'TEMPMIN','PRECIP')
    ) AS ds
    ON ds.day = re.day AND ds.vr_symbol = re.vr_symbol
 )
,grouped_data AS (
    SELECT 
        *,
        COUNT(min_value) OVER (PARTITION BY vr_symbol ORDER BY day) AS min_group,
        COUNT(max_value) OVER (PARTITION BY vr_symbol ORDER BY day) AS max_group,
        COUNT(avg_value) OVER (PARTITION BY vr_symbol ORDER BY day) AS avg_group
    FROM extended_daily_summary
),
filled_daily_summary AS (
    SELECT 
        vr_symbol,
        day,
        {{ station_id }} AS station_id,
        FIRST_VALUE(min_value) OVER (
            PARTITION BY vr_symbol, min_group 
            ORDER BY day
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS min_value,
        FIRST_VALUE(max_value) OVER (
            PARTITION BY vr_symbol, max_group 
            ORDER BY day
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS max_value,
        FIRST_VALUE(avg_value) OVER (
            PARTITION BY vr_symbol, avg_group 
            ORDER BY day
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS avg_value
    FROM grouped_data
)
,daily_data AS (
    SELECT
        st.name AS st_name
        ,st.latitude AS st_latitude
        ,fds.day
        ,EXTRACT(DOY FROM fds.day)::integer AS doy
        ,0.0023 AS alpha
        ,0.5 AS beta
        ,SUM(CASE WHEN vr_symbol = 'TEMPMIN' THEN fds.min_value END) AS temp_min
        ,SUM(CASE WHEN vr_symbol = 'TEMPMAX' THEN fds.max_value END) AS temp_max 
        ,SUM(CASE WHEN vr_symbol = 'PRECIP' THEN fds.avg_value END) AS precip
    FROM filled_daily_summary fds
    JOIN wx_station st ON st.id = fds.station_id
     WHERE day >= '{{ sim_start_date }}'::date
      AND day <= '{{ sim_end_date }}'::date    
    GROUP BY 
        st.name
        ,st.latitude
        ,fds.day
    ORDER BY day
)
SELECT
    ROUND(temp_min::numeric, 2)  AS "MinTemp"
    ,ROUND(temp_max::numeric, 2) AS "MaxTemp"
    ,ROUND(precip::numeric, 2) AS "Precipitation"
    ,ROUND(ms_hargreaves_samani_evapotranspiration(
        alpha
        ,beta
        ,temp_min
        ,temp_max
        ,st_latitude
        ,doy
    )::numeric, 2) AS "ReferenceET"
    ,day::timestamp as "Date"
    -- ,st_name
FROM daily_data