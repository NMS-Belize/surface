CREATE OR REPLACE FUNCTION extraterrestrial_radiation(
    latitude float,          -- degrees (°)
    day_of_year integer      -- (1-366)
) RETURNS float AS $$        -- MJ/m²/day
DECLARE
    solar_declination float; -- radians (rad)
    inverse_relative_earth_sun_distance float; -- dimensionless
    latitude_radians float;  -- radians (rad)
    sunset_hour_angle float; -- radians (rad)
    extraterrestrial_radiation float; -- MJ/m²/day
BEGIN
    solar_declination := 0.409 * SIN((2 * PI() / 365 * day_of_year) - 1.39);
    inverse_relative_earth_sun_distance := 1 + 0.033 * COS((2 * PI() / 365) * day_of_year);
    latitude_radians := PI() / 180 * latitude;
    sunset_hour_angle := ACOS(-TAN(latitude_radians) * TAN(solar_declination));
    
    extraterrestrial_radiation := 24 * 60 / PI() * 0.0820 * inverse_relative_earth_sun_distance * 
        (sunset_hour_angle * SIN(latitude_radians) * SIN(solar_declination) + 
         COS(latitude_radians) * COS(solar_declination) * SIN(sunset_hour_angle));
    
    RETURN extraterrestrial_radiation;
END;
$$ LANGUAGE plpgsql;

-- Hargreaves-Samani
CREATE OR REPLACE FUNCTION hargreaves_samani_evapotranspiration(
    alpha float,
    beta float,
    tmax float,              -- °C
    tmin float,              -- °C
    latitude float,
    day_of_year integer
) RETURNS float AS $$    -- kPa (saturation vapour pressure at T)
DECLARE
    extraterrestrial_rad float;
    tmean float;           -- °C
    evapotranspiration float;
BEGIN
    extraterrestrial_rad := extraterrestrial_radiation(latitude, day_of_year);
    tmean := (tmax + tmin) / 2;
    evapotranspiration := alpha * POWER((tmax - tmin), beta) * (tmean + 17.8) * extraterrestrial_rad * 0.408;
    RETURN evapotranspiration;
END;
$$ LANGUAGE plpgsql;



WITH daily_data AS (
    SELECT
        station_id
        ,'EVAPOTRANSPIRATION' AS product
        ,day
        ,EXTRACT(DAY FROM day)::integer AS day_of_month
        ,EXTRACT(DOY FROM day)::integer AS day_of_year
        ,EXTRACT(MONTH FROM day) AS month
        ,EXTRACT(YEAR FROM day) AS year
        ,st.latitude AS latitude
        ,{{alpha}} AS alpha
        ,{{beta}} AS beta
        ,MAX(CASE WHEN vr.symbol = 'TEMPMAX' THEN max_value ELSE NULL END) AS tmax
        ,MIN(CASE WHEN vr.symbol = 'TEMPMIN' THEN min_value ELSE NULL END) AS tmin
    FROM daily_summary ds
    JOIN wx_variable vr ON vr.id = ds.variable_id
    JOIN wx_station st ON st.id = ds.station_id
    WHERE station_id = {{station_id}}
      AND vr.symbol IN ('TEMPMIN', 'TEMPMAX','SOLARRAD')
      AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
    GROUP BY station_id, day, latitude
)
,evapotranspiration_calc AS(
    SELECT
        station_id
        ,day_of_month
        ,month
        ,year
        ,hargreaves_samani_evapotranspiration(alpha, beta, tmax, tmin, latitude, day_of_year) AS evapotranspiration
    FROM daily_data
)
,extended_data AS(
    SELECT
        station_id
        ,day_of_month
        ,CASE 
            WHEN month=12 THEN 0
            WHEN month=1 THEN 13
        END as month
        ,CASE 
            WHEN month=12 THEN year+1
            WHEN month=1 THEN year-1
        END as year
        ,evapotranspiration
    FROM evapotranspiration_calc
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM evapotranspiration_calc
)
SELECT
    st.name AS station
    ,'EVAPOTRANSPIRATION' AS product
    ,year
    ,month
    ,day_of_month
    ,evapotranspiration
FROM extended_data ed
JOIN wx_station st ON st.id=ed.station_id
WHERE year BETWEEN {{start_year}} AND {{end_year}}  
    AND month in ({{aggregation_months}})