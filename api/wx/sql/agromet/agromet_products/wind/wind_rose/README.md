Wind Rose Analysis

This SQL analyzes wind direction distribution:

1. Converts wind direction angles (over avg_value of WNDDIR) into 8 cardinal/intercardinal directions (N, NE, E, SE, S, SW, W, NW)

2. For each time period, counts frequency of wind from each direction

3. Results show percentage of time wind comes from each direction, grouped by seasonal periods (JFM, FMA, MAM, etc.)
