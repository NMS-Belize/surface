Growing Degree Days (GDD) Calculation

This SQL calculates growing degree days, which measures heat accumulation for plant growth:

1. Daily calculation: GDD = max((Tmin + Tmax)/2 - base_temp, 0)
   where base_temp is a parameter
   Tmin is over min_value of ('TEMP', 'TEMPMIN', 'TEMPMAX') 
   Tmax is over max_value of ('TEMP', 'TEMPMIN', 'TEMPMAX') 

2. Results are aggregated into seasonal periods (JFM, FMA, MAM, etc.) and annual totals by summing up GDDs