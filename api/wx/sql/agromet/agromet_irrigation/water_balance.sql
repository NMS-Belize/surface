-- -- Allen et al. (1998), FAO-56 (Equation 50).
-- CREATE OR REPLACE FUNCTION solar_radiation(
--     tmin float,                 -- °C
--     tmax float,                 -- °C
--     R_a float,                  -- MJ/m²/day (extraterrestrial radiation)
--     inland_station boolean DEFAULT TRUE
-- ) RETURNS float AS $$           -- MJ/m²/day
-- DECLARE
--     R_s float;                  -- MJ/m²/day (solar radiation)
-- BEGIN
--     IF inland_station THEN
--         R_s := 0.16 * SQRT(tmax - tmin) * R_a;
--     ELSE
--         R_s := 0.19 * SQRT(tmax - tmin) * R_a;
--     END IF;
--     RETURN R_s;
-- END;
-- $$ LANGUAGE plpgsql;

WITH crop_data AS (
    SELECT
        id,
        name,
        cycle,
        max_ht,
        l_ini,
        l_dev,
        l_mid,
        l_late,
        kc_ini,
        kc_mid,
        kc_end
    FROM wx_crop
    WHERE id = {{ crop_id }}
)
SELECT
    station_id
    ,day
    ,day::date - '{{ emergence_date }}'::date AS days_since_emergence
    ,crop_data.name AS crop_name
    ,crop_data.cycle AS cycle
    ,crop_data.max_ht AS max_ht
    ,crop_data.l_ini AS l_ini
    ,crop_data.l_dev AS l_dev
    ,crop_data.l_mid AS l_mid
    ,crop_data.l_late AS l_late
    ,crop_data.kc_ini AS kc_ini
    ,crop_data.kc_mid AS kc_mid
    ,crop_data.kc_end AS kc_end
    ,SUM(CASE WHEN vr.symbol = 'TEMP' THEN avg_value END) AS temp
    ,SUM(CASE WHEN vr.symbol = 'TEMPMAX' THEN avg_value END) AS temp_max
    ,SUM(CASE WHEN vr.symbol = 'TEMPMIN' THEN avg_value END) AS temp_min
    ,SUM(CASE WHEN vr.symbol = 'PRECIP' THEN avg_value END) AS precip
    ,SUM(CASE WHEN vr.symbol = 'PRESSTN' THEN avg_value END) AS pressure 
    ,SUM(CASE WHEN vr.symbol = 'WINDSPD' THEN avg_value END) AS wind_speed
    ,SUM(CASE WHEN vr.symbol = 'SOLARRAD' THEN avg_value END) AS solar_rad
    ,SUM(CASE WHEN vr.symbol = 'RH' THEN avg_value END) AS rh   
FROM daily_summary ds
JOIN wx_variable vr ON vr.id = ds.variable_id
JOIN wx_station st ON st.id = ds.station_id
CROSS JOIN crop_data
WHERE
    station_id = {{ station_id }}
    AND vr.symbol IN ('TEMP', 'TEMPMAX', 'TEMPMIN', 'PRECIP', 'PRESSTN', 'WINDSPD', 'SOLARRAD', 'RH')
    AND day >= '{{ emergence_date }}'::date
    AND day <= '{{ emergence_date }}'::date + (crop_data.cycle || ' days')::interval
GROUP BY station_id, day, crop_data.id, crop_data.name, crop_data.cycle, crop_data.max_ht, crop_data.l_ini, crop_data.l_dev, crop_data.l_mid, crop_data.l_late, crop_data.kc_ini, crop_data.kc_mid, crop_data.kc_end
ORDER BY day;