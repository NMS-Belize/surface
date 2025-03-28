SELECT
  ROUND(PERCENTILE_CONT({{percentile}}/100.0) WITHIN GROUP (ORDER BY ds.max_value)::numeric, 2)
FROM daily_summary ds
JOIN wx_variable vr ON vr.id=ds.variable_id
WHERE ds.station_id={{station_id}} AND vr.symbol='TEMPMAX'