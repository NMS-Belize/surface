WITH daily_data AS (
    SELECT
        ds.day
        ,SUM(CASE WHEN vr.symbol = 'TEMP' THEN ds.min_value END) AS temp_min
        ,SUM(CASE WHEN vr.symbol = 'TEMP' THEN ds.max_value END) AS temp_max
        ,SUM(CASE WHEN vr.symbol = 'PRECIP' THEN ds.avg_value END) AS precip
        ,SUM(CASE WHEN vr.symbol = 'PRESSTN' THEN ds.avg_value END) AS pressure 
        ,SUM(CASE WHEN vr.symbol = 'WNDSPAVG' THEN ds.avg_value END) AS wind_speed
        ,SUM(CASE WHEN vr.symbol = 'SOLARRAD' THEN ds.avg_value END) AS solar_rad
        ,SUM(CASE WHEN vr.symbol = 'RH' THEN ds.avg_value END) AS rh  
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    WHERE station_id = {{ station_id }}
      AND vr.symbol IN ('PRECIP', 'TEMP','PRESSTN', 'WNDSPAVG','SOLARRAD', 'RH')
      AND day >= '{{ sim_start_date }}'::date
      AND day <= '{{ sim_end_date }}'::date
    GROUP BY ds.day
    ORDER BY day
)
SELECT
    COUNT(*) AS "Days"
    ,COUNT(*) FILTER(WHERE dd.temp_min IS NOT NULL) AS "MinTempCount"
    ,MIN(dd.day) FILTER(WHERE dd.temp_min IS NOT NULL) AS "MinTempMinDay"
    ,MAX(dd.day) FILTER(WHERE dd.temp_min IS NOT NULL) AS "MinTempMaxDay"
    ,COUNT(*) FILTER(WHERE dd.temp_max IS NOT NULL) AS "MaxTempCount"
    ,MIN(dd.day) FILTER(WHERE dd.temp_max IS NOT NULL) AS "MaxTempMinDay"
    ,MAX(dd.day) FILTER(WHERE dd.temp_max IS NOT NULL) AS "MaxTempMaxDay"
    ,COUNT(*) FILTER(WHERE dd.precip IS NOT NULL) AS "PrecipitationCount"
    ,MIN(dd.day) FILTER(WHERE dd.precip IS NOT NULL) AS "PrecipitationMinDay"
    ,MAX(dd.day) FILTER(WHERE dd.precip IS NOT NULL) AS "PrecipitationMaxDay"
    ,COUNT(*) FILTER(WHERE dd.pressure IS NOT NULL) AS "AtmosphericPressureCount"
    ,MIN(dd.day) FILTER(WHERE dd.pressure IS NOT NULL) AS "AtmosphericPressureMinDay"
    ,MAX(dd.day) FILTER(WHERE dd.pressure IS NOT NULL) AS "AtmosphericPressureMaxDay"
    ,COUNT(*) FILTER(WHERE dd.wind_speed IS NOT NULL) AS "WindSpeedCount"
    ,MIN(dd.day) FILTER(WHERE dd.wind_speed IS NOT NULL) AS "WindSpeedMinDay"
    ,MAX(dd.day) FILTER(WHERE dd.wind_speed IS NOT NULL) AS "WindSpeedMaxDay"
    ,COUNT(*) FILTER(WHERE dd.solar_rad IS NOT NULL) AS "SolarRadiationCount"
    ,MIN(dd.day) FILTER(WHERE dd.solar_rad IS NOT NULL) AS "SolarRadiationMinDay"
    ,MAX(dd.day) FILTER(WHERE dd.solar_rad IS NOT NULL) AS "SolarRadiationMaxDay"
    ,COUNT(*) FILTER(WHERE dd.rh IS NOT NULL) AS "RelativeHumidityCount"
    ,MIN(dd.day) FILTER(WHERE dd.rh IS NOT NULL) AS "RelativeHumidityMinDay"
    ,MAX(dd.day) FILTER(WHERE dd.rh IS NOT NULL) AS "RelativeHumidityMaxDay"    
FROM (SELECT generate_series('{{ sim_start_date }}'::date, '{{ sim_end_date }}'::date, '1 DAY'::interval)::date AS day) AS days
LEFT JOIN daily_data dd ON dd.day = days.day