Heat Wave Detection

This SQL identifies and counts heat wave events:

1. A heat wave is defined when minimum temperature (over min_value of ('TEMP', 'TEMPMIN', 'TEMPMAX')) exceeds a threshold for a specified number of consecutive days (heat_wave_window)

2. For each day, checks if previous N days (where N = heat_wave_window) were all above threshold with no gaps

3. Results show number of heat wave events per seasonal period (JFM, FMA, MAM, etc.)
