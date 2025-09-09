WITH daily_data AS (
    SELECT
        st.name AS st_name
        ,st.latitude AS st_latitude
        ,st.elevation AS st_elevation
        ,ds.day
        ,EXTRACT(DOY FROM ds.day)::integer AS doy
        ,SUM(CASE WHEN vr.symbol = 'TEMP' THEN ds.min_value END) AS temp_min
        ,SUM(CASE WHEN vr.symbol = 'TEMP' THEN ds.max_value END) AS temp_max
        ,SUM(CASE WHEN vr.symbol = 'PRECIP' THEN ds.avg_value END) AS precip
        ,SUM(CASE WHEN vr.symbol = 'PRESSTN' THEN ds.avg_value END) AS pressure 
        ,SUM(CASE WHEN vr.symbol = 'WNDSPAVG' THEN ds.avg_value END) AS wind_speed
        ,SUM(CASE WHEN vr.symbol = 'SOLARRAD' THEN ds.avg_value END) AS solar_rad
        ,SUM(CASE WHEN vr.symbol = 'RH' THEN ds.avg_value END) AS rh   
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    JOIN wx_station st ON st.id = ds.station_id
    WHERE station_id = {{ station_id }}
      AND vr.symbol IN ('TEMP','SOLARRAD', 'RH', 'PRESSTN', 'PRECIP', 'WNDSPAVG')
      AND day >= '{{ sim_start_date }}'::date
      AND day <= '{{ sim_end_date }}'::date
    GROUP BY 
        st.name
        ,st.latitude
        ,st.elevation
        ,ds.day
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