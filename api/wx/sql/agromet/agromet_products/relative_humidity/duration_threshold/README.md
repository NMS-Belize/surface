Relative Humidity Duration Analysis

This SQL analyzes periods of sustained high humidity:

1. Identifies days where relative humidity (over avg_value of RH) exceeds threshold value

2. Groups consecutive days of high humidity into sequences

3. For each time period (seasonal and annual), finds the longest continuous sequence of high humidity days