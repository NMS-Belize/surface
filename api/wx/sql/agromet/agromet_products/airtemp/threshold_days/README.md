Temperature Threshold Days

This SQL counts days relative to a temperature threshold:

1. For each day, compares average temperature (over avg_value of TEMP) with a specified threshold value

2. Counts number of days that are:
   - Above threshold
   - Equal to threshold
   - Below threshold