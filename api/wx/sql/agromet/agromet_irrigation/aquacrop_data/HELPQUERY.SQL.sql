SELECT 
    st.id
    ,st.name
    ,vr.symbol
    ,COUNT(*)
    ,MIN(ds.day) AS first_date
    ,MAX(ds.day) AS last_date
FROM daily_summary ds
JOIN wx_station st ON st.id=ds.station_id
JOIN wx_variable vr ON vr.id=ds.variable_id
WHERE st.is_automatic
  AND st.is_active
--   AND day > '2010-01-01'
--   AND day < '2018-01-01'
    AND vr.symbol IN('WNDCHILL','WNDMILE','WNDDRMSD','WNDSPMH','WNDSPD','WNDSPMIN','WNDDSTDV', 'WNDMIL', 'WINDRUN','WNDDAVG','WNDDIR','WNDSPMAX','WNDSPAVG')
--   AND vr.symbol IN  ('WNDSPD')-- ('PRECIP','TEMP','SOLARRAD', 'RH', 'PRESSTN',  'WNDSPD')
--   AND vr.symbol IN ('PRECIP','TEMPMIN','TEMPMAX')
GROUP BY st.id, st.name, vr.symbol
ORDER BY st.id, vr.symbol;