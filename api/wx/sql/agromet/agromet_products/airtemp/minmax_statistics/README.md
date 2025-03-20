Temperature Min/Max Statistics

This SQL calculates temperature extremes:

1. For each time period (seasonal and annual), finds:
   - Minimum temperature (over min_value of ('TEMP', 'TEMPMIN', 'TEMPMAX')) (lowest recorded temperature)
   - Maximum temperature (over max_value of ('TEMP', 'TEMPMIN', 'TEMPMAX')) (highest recorded temperature)