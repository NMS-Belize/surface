WITH requested_entries AS (
    SELECT 
        day
        ,vr_symbol
    FROM (SELECT generate_series('{{ sim_start_date }}'::date, '{{ sim_end_date }}'::date, '1 DAY'::interval)::date AS day) AS days
    CROSS JOIN (VALUES ('TEMP'),('SOLARRAD'),('RH'),('PRESSTN'),('PRECIP'),('WNDSPAVG')) AS variable_symbols(vr_symbol)
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
          AND vr.symbol IN ('TEMP','SOLARRAD', 'RH', 'PRESSTN', 'PRECIP', 'WNDSPAVG')
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
        ,st.elevation AS st_elevation
        ,fds.day
        ,EXTRACT(DOY FROM fds.day)::integer AS doy
        ,SUM(CASE WHEN fds.vr_symbol = 'TEMP' THEN fds.min_value END) AS temp_min
        ,SUM(CASE WHEN fds.vr_symbol = 'TEMP' THEN fds.max_value END) AS temp_max
        ,SUM(CASE WHEN fds.vr_symbol = 'PRECIP' THEN fds.avg_value END) AS precip
        ,SUM(CASE WHEN fds.vr_symbol = 'PRESSTN' THEN fds.avg_value END) AS pressure 
        ,SUM(CASE WHEN fds.vr_symbol = 'WNDSPAVG' THEN fds.avg_value END) AS wind_speed
        ,SUM(CASE WHEN fds.vr_symbol = 'SOLARRAD' THEN fds.avg_value END) AS solar_rad
        ,SUM(CASE WHEN fds.vr_symbol = 'RH' THEN fds.avg_value END) AS rh   
    FROM filled_daily_summary fds
    JOIN wx_station st ON st.id = fds.station_id
    WHERE day >= '{{ sim_start_date }}'::date
      AND day <= '{{ sim_end_date }}'::date
    GROUP BY 
        st.name
        ,st.latitude
        ,st.elevation
        ,fds.day
    ORDER BY day
)
SELECT
    ROUND(temp_min::numeric, 2)  AS "MinTemp"
    ,ROUND(temp_max::numeric, 2) AS "MaxTemp"
    ,ROUND(precip::numeric, 2) AS "Precipitation"
    ,ROUND(as_penman_monteith_evapotranspiration(
        temp_min
        ,temp_max
        ,pressure
        ,wind_speed
        ,solar_rad
        ,rh
        ,st_latitude
        ,st_elevation
        ,doy
    )::numeric, 2) AS "ReferenceET"
    ,day::timestamp as "Date"
    -- ,st_name
FROM daily_data