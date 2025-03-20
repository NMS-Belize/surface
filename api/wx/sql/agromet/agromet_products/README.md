# Agromet Products SQL Calculations

This document explains the calculations performed in each SQL file within the agromet_products directory.

## Air Temperature

### Growing Degree Days (GDD)
- Validation Status: (❌)
- Daily calculation: `GDD = max((Tmin + Tmax)/2 - base_temp, 0)`
  - where base_temp is a parameter
  - Tmin is over min_value of ('TEMP', 'TEMPMIN', 'TEMPMAX') 
  - Tmax is over max_value of ('TEMP', 'TEMPMIN', 'TEMPMAX') 
- Results are aggregated into seasonal periods (JFM, FMA, MAM, etc.) and annual totals by summing up GDDs

### Heat Wave Events
- Validation Status: (❌)
- A heat wave is defined when minimum temperature (over min_value of ('TEMP', 'TEMPMIN', 'TEMPMAX')) exceeds a threshold for a specified number of consecutive days (heat_wave_window)
- For each day, checks if previous N days (where N = heat_wave_window) were all above threshold with no gaps

### Temperature Min/Max Statistics
- Validation Status: (❌)
For each time period (seasonal and annual), finds:
- Minimum temperature (over min_value of ('TEMP', 'TEMPMIN', 'TEMPMAX')) (lowest recorded temperature)
- Maximum temperature (over max_value of ('TEMP', 'TEMPMIN', 'TEMPMAX')) (highest recorded temperature)

### Temperature Threshold Days
- Validation Status: (❌)
Counts days relative to a temperature threshold:
- Compares average temperature (over avg_value of TEMP) with a specified threshold value
- Counts days that are:
  - Above threshold
  - Equal to threshold
  - Below threshold

## Rainfall

### Rainfall Threshold Days
- Validation Status: (❌)
- Compares precipitation amount (over sum_value of PRECIP) with a specified threshold value
- Counts number of days where rainfall is above threshold

## Relative Humidity

### Duration Above Threshold
- Validation Status: (❌)
- Identifies days where relative humidity (over avg_value of RH) exceeds threshold value
- Groups consecutive days of high humidity into sequences
- For each time period (seasonal and annual), finds the longest continuous sequence of high humidity days

## Wind

### Wind Rose Analysis
- Validation Status: (❌)
- Converts wind direction angles (over avg_value of WNDDIR) into 8 cardinal/intercardinal directions (N, NE, E, SE, S, SW, W, NW)
- For each time period, counts frequency of wind from each direction
- Results show percentage of time wind comes from each direction

### Maximum and Average Wind Speed
- Validation Status: (❌)
For each time period (seasonal and annual), calculates (over avg_value of WNDSPD):
- Maximum wind speed (highest recorded value)
- Average wind speed (mean of daily averages)

### Wind Speed Threshold Days
- Validation Status: (❌)
- For each day, identifies if average wind speed (over avg_value of WNDSPD) is below specified threshold
- Counts number of low wind speed days for each time period
