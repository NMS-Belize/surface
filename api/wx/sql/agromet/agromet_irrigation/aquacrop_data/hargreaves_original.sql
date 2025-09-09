WITH daily_data AS (
    SELECT
        st.name AS st_name
        ,st.latitude AS st_latitude
        ,ds.day
        ,0.0023 AS alpha
        ,0.5 AS beta
        ,EXTRACT(DOY FROM ds.day)::integer AS doy
        ,SUM(CASE WHEN vr.symbol = 'TEMPMIN' THEN ds.min_value END) AS temp_min
        ,SUM(CASE WHEN vr.symbol = 'TEMPMAX' THEN ds.max_value END) AS temp_max 
        ,SUM(CASE WHEN vr.symbol = 'PRECIP' THEN ds.avg_value END) AS precip
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    JOIN wx_station st ON st.id = ds.station_id
    WHERE station_id = {{ station_id }}
      AND vr.symbol IN ('TEMPMAX', 'TEMPMIN','PRECIP')
      AND day >= '{{ sim_start_date }}'::date
      AND day <= '{{ sim_end_date }}'::date
    GROUP BY 
        st.name
        ,st.latitude
        ,ds.day
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