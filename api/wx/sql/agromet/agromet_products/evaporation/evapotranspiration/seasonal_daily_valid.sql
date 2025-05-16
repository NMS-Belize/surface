-- Daily Data from Daily Summary
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
      AND vr.symbol IN ('TEMPMIN', 'TEMPMAX')
      AND '{{ start_date }}' <= day AND day < '{{ end_date }}'
    GROUP BY station_id, day, latitude
)
,evapotranspiration_calc AS(
    SELECT
        station_id
        ,day_of_month
        ,month
        ,year
        ,ms_hargreaves_samani_evapotranspiration(alpha, beta, tmin, tmax, latitude, day_of_year) AS hargreaves_samani
    FROM daily_data
    WHERE tmin IS NOT NULL
      AND tmax IS NOT NULL
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
        ,hargreaves_samani
    FROM evapotranspiration_calc
    WHERE month in (1,12)
    UNION ALL
    SELECT * FROM evapotranspiration_calc
)
SELECT
    st.name AS station
    ,'HARGREAVES-SAMANI (mm)' AS product
    ,year
    ,month AS "Month"
    ,day_of_month AS "Day"
    ,ROUND(hargreaves_samani::numeric, 1) AS "Evapotranspiration (mm)"
FROM extended_data ed
JOIN wx_station st ON st.id=ed.station_id
WHERE year BETWEEN {{start_year}} AND {{end_year}}  
    AND month in ({{aggregation_months}})