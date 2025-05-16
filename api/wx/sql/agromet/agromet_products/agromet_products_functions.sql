-- Drought indices functions
CREATE OR REPLACE FUNCTION fit_gamma(value float[]) RETURNS float[] AS $$
DECLARE
    mean_val float;
    var_val float;
    mean_log float;
    n integer;
    k float;
    theta float;
    k_initial float;
    s float;
BEGIN
    -- Calculate basic statistics (only positive values)
    SELECT AVG(x), VARIANCE(x), AVG(LN(x)), COUNT(x)
    INTO mean_val, var_val, mean_log, n
    FROM unnest(value) AS x
    WHERE x > 0;
    
    -- Handle case with no positive values
    IF n = 0 OR var_val = 0 THEN
        RETURN ARRAY[NULL, NULL];
    END IF;
    
    -- Initial estimate using method of moments
    k_initial := (mean_val * mean_val) / var_val;
    k := k_initial;
    
    -- Approximation of digamma function (for positive arguments)
    -- Using the first few terms of the Taylor series expansion
    -- For more accuracy, you could implement a more complete approximation
    s := LN(mean_val) - mean_log;
    
    -- Approximate solution for k (shape parameter)
    -- Using approximation from Minka (2002) "Estimating a Gamma distribution"
    IF s < 0.5772156649 THEN  -- Euler-Mascheroni constant
        k := (0.5000876 + 0.1648852*s - 0.0544274*s*s)/s;
    ELSE
        k := (8.898919 + 9.059950*s + 0.9775373*s*s)/
             (s*(17.79728 + 11.968477*s + s*s));
    END IF;
    
    -- Calculate scale parameter
    theta := mean_val / k;
    
    RETURN ARRAY[k, theta];
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION soil_deficit_function(
    soil_moisture_m float,        -- Value of soil moisture for a particular month
    min_soil_moisture_t float,    -- Minimum value of soil moisture in all data for that particular month
    max_soil_moisture_t float,    -- Maximum value of soil moisture in all data for that particular month
    avg_soil_moisture_t float     -- Average value of soil moisture in all data for that particular month
) RETURNS float AS $$
DECLARE
    soil_deficit float;
BEGIN
    IF soil_moisture_m <= avg_soil_moisture_t THEN
        soil_deficit := 100*
            (soil_moisture_m - avg_soil_moisture_t)/
            (avg_soil_moisture_t - min_soil_moisture_t);
    ELSE
        soil_deficit := 100*
            (soil_moisture_m - avg_soil_moisture_t)/
            (max_soil_moisture_t - avg_soil_moisture_t);
    END IF;
    
    RETURN soil_deficit;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION smdi_function(sd_values float[]) 
RETURNS float[] AS $$
DECLARE
    smdi_results float[] := '{}';
    smdi_prev float := 0;
    smdi_curr float;
    sd_curr float;
BEGIN
    FOREACH sd_curr IN ARRAY sd_values LOOP
        IF sd_curr IS NULL THEN smdi_curr := NULL;
        ELSE smdi_curr := 0.5 * COALESCE(smdi_prev, 0) + (sd_curr / 50);
        END IF;

        smdi_results := smdi_results || smdi_curr;
        
        IF smdi_curr IS NOT NULL THEN smdi_prev := smdi_curr;
        END IF;
    END LOOP;
    
    RETURN smdi_results;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- Linear Calculation Based on GDD and Precipitation
CREATE OR REPLACE FUNCTION leaf_area_index(
    tmax float,             -- °C
    tmin float,             -- °C
    tbase float,             -- °C
    precip float             -- mm
) RETURNS float AS $$    -- °C
DECLARE
    gdd float;           -- °C
    lai float;           -- 
BEGIN
    gdd := growing_degree_days(tmin, tmax,tbase);

    IF gdd IS NULL THEN
        RETURN NULL;
    END IF;

    lai := 0.5 +  0.02 * gdd +  0.05  * precip;
    RETURN lai;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION consecutive_flag_calc(
    flag_arr boolean[],
    reset_arr boolean[]
) RETURNS integer[] AS $$
DECLARE
    consecutive_seq integer[] := '{}';
    consecutive_count int := 0;
    index int;
BEGIN
    IF flag_arr IS NULL THEN RETURN consecutive_seq;
    END IF;

    FOR index IN 1 .. array_length(flag_arr, 1) LOOP
        IF NOT flag_arr[index] THEN consecutive_count := 0;
        ELSIF reset_arr[index] THEN consecutive_count := 1;
        ELSE consecutive_count := consecutive_count + 1;
        END IF;

        consecutive_seq := consecutive_seq || consecutive_count;
    END LOOP;

    RETURN consecutive_seq;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- https://www.fao.org/4/x0490e/x0490e07.htm#chapter%203%20%20%20meteorological%20data

-- Allen et al. (1998), FAO-56 (Equation 10).
CREATE OR REPLACE FUNCTION relative_humidity(
    tmax float,             -- °C
    tmin float              -- °C
) RETURNS float AS $$        -- %
DECLARE
    e_tmin float;           -- kPa (saturation vapour pressure at Tmin)
    e_tmax float;           -- kPa (saturation vapour pressure at Tmax)
    e_s float;              -- kPa (mean saturation vapour pressure)
    e_a float;              -- kPa (actual vapour pressure)
    rh float;               -- %
BEGIN
    -- Saturation vapour Pressure (e_t) FAO-56 (Equation 11)
    e_tmin := saturation_vapour_pressure(tmin);
    e_tmax := saturation_vapour_pressure(tmax);

    -- Mean Saturation vapour Pressure (e_s) FAO-56 (Equation 12)
    e_s := (e_tmin + e_tmax) / 2;

    -- FAO-56 Equation 48
    e_a := e_tmin;

    -- FAO-56 Equation 10
    rh := (e_a / e_s) * 100;
    RETURN rh;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION growing_degree_days(
    tmin float,         -- °C
    tmax float,         -- °C
    tbase float         -- °C
) RETURNS float AS $$   -- °C
DECLARE
    gdd float;          -- °C
BEGIN
    IF NULL IN (tmax, tmin, tbase) THEN RETURN NULL;
    END IF;

    gdd := GREATEST(0, (tmax+tmin) / 2.0 - tbase);
    RETURN gdd;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 21).
CREATE OR REPLACE FUNCTION extraterrestrial_radiation(
    D_r float,                     -- Dimensionless (inverse relative Earth-Sun distance) [FAO-56 Eq.23]
    omega_s float,                 -- Radians (sunset hour angle) [FAO-56 Eq.25]
    phi float,                     -- Radians (latitude) 
    delta float,                   -- Radians (solar declination) [FAO-56 Eq.24]
    G_sc float DEFAULT 0.0820      -- MJ/m²/min (solar constant) 
) RETURNS float AS $$              -- MJ/m²/day (daily extraterrestrial radiation)
DECLARE
    R_a float;                     -- MJ/m²/day (extraterrestrial radiation)
BEGIN
    R_a := ((24 * 60 )/ PI()) * G_sc * D_r * (
        omega_s * SIN(phi) * SIN(delta) + COS(phi) * COS(delta) * SIN(omega_s)
    );
    RETURN R_a;
END;
$$ LANGUAGE plpgsql;

-- Hargreaves-Samani
CREATE OR REPLACE FUNCTION hargreaves_samani_evapotranspiration(
    alpha float,
    beta float,
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    T float,                       -- °C (mean daily air temperature at 2m)
    R_a float                     -- MJ/m²/day (extraterrestrial radiation)
) RETURNS float AS $$              -- 
DECLARE
    ET_0 float;
BEGIN
    ET_0 := alpha * POWER((tmax - tmin), beta) * (T + 17.8) * R_a * 0.408;
    RETURN ET_0;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 37).
CREATE OR REPLACE FUNCTION clearsky_radiation(
    R_a float,                     -- MJ/m²/day (extraterrestrial radiation)
    z float                        -- m (station elevation above sea level)
) RETURNS float AS $$              -- MJ/m²/day (clear-sky solar radiation)
DECLARE
    R_so float;                    -- MJ/m²/day (clear-sky solar radiation)
BEGIN
    R_so := R_a * (0.75 + (2 * 10^(-5)) * z);
    RETURN R_so;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 11).
CREATE OR REPLACE FUNCTION saturation_vapour_pressure(
    t float                        -- °C (air temperature)
) RETURNS float AS $$              -- kPa (saturation vapour pressure)
DECLARE
    e_t float;                     -- kPa (saturation vapour pressure at temperature t)
BEGIN
    e_t := 0.6108 * EXP((17.27 * t) / (t + 237.3));
    RETURN e_t;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 19)
CREATE OR REPLACE FUNCTION actual_vapour_pressure(
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    rh float                       -- % (relative humidity)
) RETURNS float AS $$              -- kPa (actual vapour pressure)
DECLARE
    e_tmin float;                  -- kPa (saturation vapour pressure at tmin)
    e_tmax float;                  -- kPa (saturation vapour pressure at tmax)
    e_s float;                     -- kPa (mean saturation vapour pressure)
    e_a float;                     -- kPa (actual vapour pressure)
BEGIN
    e_tmin := saturation_vapour_pressure(tmin);
    e_tmax := saturation_vapour_pressure(tmax);
    e_s := (e_tmin + e_tmax)/2;
    e_a := rh/100 * e_s;
    RETURN e_a;
END;
$$ LANGUAGE plpgsql;



-- Allen et al. (1998), FAO-56 (Equation 38).
CREATE OR REPLACE FUNCTION net_shortwave_radiation(
    R_s float,                     -- MJ/m²/day (solar radiation)
    albedo float DEFAULT 0.23      -- dimensionless (surface albedo)
) RETURNS float AS $$              -- MJ/m²/day (net shortwave radiation)
DECLARE
    R_sn float;                    -- MJ/m²/day (net shortwave radiation)
BEGIN
    R_sn := (1 - albedo) * R_s;
    RETURN R_sn;
END;
$$ LANGUAGE plpgsql;


-- Allen et al. (1998), FAO-56 Equation 39
CREATE OR REPLACE FUNCTION net_longwave_radiation(
    tmin_k float,                  -- K (daily minimum temperature in Kelvin)
    tmax_k float,                  -- K (daily maximum temperature in Kelvin)
    R_s float,                     -- MJ/m²/day (solar radiation)
    R_so float,                    -- MJ/m²/day (clear-sky radiation)
    e_a float,                     -- kPa (actual vapour pressure)
    sigma float DEFAULT 4.903e-9   -- MJ K⁻⁴ m⁻² day⁻¹ (Stefan-Boltzmann constant)
) RETURNS float AS $$              -- MJ/m²/day (net longwave radiation)
DECLARE
    R_nl float;                    -- MJ/m²/day (net longwave radiation)
BEGIN
    R_nl := sigma * (
        ((POWER(tmax_k, 4) + POWER(tmin_k, 4)) / 2) *
        (0.34 - 0.14 * SQRT(e_a)) *
        (1.35 * (R_s / R_so) - 0.35)
    );
    RETURN R_nl;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 50).
CREATE OR REPLACE FUNCTION solar_radiation(
    tmin float,                 -- °C
    tmax float,                 -- °C
    R_a float,                  -- MJ/m²/day (extraterrestrial radiation)
    inland_station boolean DEFAULT TRUE
) RETURNS float AS $$           -- MJ/m²/day
DECLARE
    R_s float;                  -- MJ/m²/day (solar radiation)
BEGIN
    IF inland_station THEN
        R_s := 0.16 * SQRT(tmax - tmin) * R_a;
    ELSE
        R_s := 0.19 * SQRT(tmax - tmin) * R_a;
    END IF;
    RETURN R_s;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 40).
CREATE OR REPLACE FUNCTION net_radiation(
    R_ns float,                    -- MJ/m²/day (net shortwave radiation)
    R_nl float                     -- MJ/m²/day (net longwave radiation)
) RETURNS float AS $$              -- MJ/m²/day (net radiation)
DECLARE
    R_n float;                     -- MJ/m²/day (net radiation)
BEGIN
    R_n := R_ns - R_nl;
    RETURN R_n;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equations 45 and 46)
CREATE OR REPLACE FUNCTION soil_heat_flux(
    R_s float,                     -- MJ/m²/day (solar radiation)
    R_n float                      -- MJ/m²/day (net radiation)
) RETURNS float AS $$              -- MJ/m²/day (soil heat flux)
DECLARE
    G float;                       -- MJ/m²/day (soil heat flux)
BEGIN
    IF R_s > 0 THEN
        G := 0.1 * R_n;  -- Daytime (FAO-56 Equation 45)
    ELSE
        G := 0.5 * R_n;  -- Nighttime (FAO-56 Equation 46)
    END IF;
    RETURN G;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 13)
CREATE OR REPLACE FUNCTION slope_saturation_vapour_pressure_curve(
    t float                        -- °C (mean air temperature)
) RETURNS float AS $$              -- kPa/°C (slope of vapour pressure curve)
DECLARE
    e_t float;                     -- kPa (saturation vapour pressure at t)
    delta float;                   -- kPa/°C (slope of vapour pressure curve)
BEGIN
    e_t := saturation_vapour_pressure(t);
    delta := (4098 * e_t) / POWER((t + 237.3), 2);
    RETURN delta;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION penman_monteith_evapotranspiration(
    R_n float,                     -- MJ/m²/day (net radiation)
    G float,                       -- MJ/m²/day (soil heat flux)
    T float,                       -- °C (mean daily air temperature at 2m)
    u_2 float,                     -- m/s (wind speed at 2m height)
    e_s float,                     -- kPa (saturation vapour pressure)
    e_a float,                     -- kPa (actual vapour pressure)
    delta float,                   -- kPa/°C (slope vapour pressure curve)
    gamma float                    -- kPa/°C (psychrometric constant)
) RETURNS float AS $$              -- mm/day (reference evapotranspiration)
DECLARE
    ET_0 float;                    -- mm/day (reference evapotranspiration)
BEGIN
    ET_0 := (
        (0.408 * delta * (R_n - G)) + (gamma * (900/(T + 273)) * u_2 * (e_s - e_a))
    ) / (
        delta + (gamma * (1 + 0.34 * u_2))
    );
    RETURN ET_0;
END;
$$ LANGUAGE plpgsql;

-- Manual Station Functions

CREATE OR REPLACE FUNCTION ms_solar_radiation(
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    latitude float,                -- ° (latitude in decimal degrees)
    day_of_year integer,           -- 1-366 (day of year)
    inland_station boolean DEFAULT TRUE
) RETURNS float AS $$              -- MJ/m²/day
DECLARE
    D_r float;                     -- Dimensionless (inverse relative Earth-Sun distance) [FAO-56 Eq.23]
    omega_s float;                 -- Radians (sunset hour angle) [FAO-56 Eq.25]
    phi float;                     -- Radians (latitude) 
    delta float;                   -- Radians (solar declination) [FAO-56 Eq.24]
    R_a float;                     -- MJ/m²/day (extraterrestrial radiation)
    R_s float;                     -- MJ/m²/day (solar radiation)
BEGIN
    -- Convert latitude to radians
    phi := latitude * (PI() / 180);
    
    -- Solar declination [FAO-56 Eq.24]
    delta := 0.409 * SIN((2 * PI() / 365 * day_of_year) - 1.39);
    
    -- Sunset hour angle [FAO-56 Eq.25]
    omega_s := ACOS(-TAN(phi) * TAN(delta));    
    
    -- Inverse relative distance [FAO-56 Eq.23]
    D_r := 1 + 0.033 * COS((2 * PI() / 365) * day_of_year);    
    
    -- Extraterrestrial radiation [FAO-56 Eq.21]
    R_a := extraterrestrial_radiation(D_r, omega_s, phi, delta);

    R_s := solar_radiation(tmin, tmax, R_a, inland_station);
    RETURN R_s;
END;
$$ LANGUAGE plpgsql;

-- Allen et al. (1998), FAO-56 (Equation 38).
CREATE OR REPLACE FUNCTION ms_net_shortwave_radiation(
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    latitude float,                -- ° (latitude in decimal degrees)
    day_of_year integer,           -- 1-366 (day of year)
    inland_station boolean DEFAULT TRUE,
    albedo float DEFAULT 0.23      -- dimensionless (surface albedo)
) RETURNS float AS $$               -- w/m²/day (net shortwave radiation)
DECLARE
    phi float;                     -- rad (latitude in radians)
    delta float;                   -- rad (solar declination)
    omega_s float;                 -- rad (sunset hour angle)
    D_r float;                     -- dimless (inverse relative distance)
    R_a float;                     -- MJ/m²/day (extraterrestrial radiation)
    R_s float;                     -- MJ/m²y (solar radiation)
    R_sn float;                    -- MJ/m²/day (net shortwave radiation)
BEGIN
    -- Solar radiation
    R_s := ms_solar_radiation(tmin, tmax, latitude, day_of_year, inland_station);

    -- Net shortwave radiation
    R_sn := (1 - albedo) * R_s;
    RETURN R_sn;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ms_net_longwave_radiation(
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    latitude float,                -- ° (latitude in decimal degrees)
    elevation float,               -- m (station elevation)
    day_of_year integer,           -- 1-366 (day of year)
    inland_station boolean DEFAULT TRUE
) RETURNS float AS $$              -- MJ/m²/day (net radiation)
DECLARE
    phi float;                     -- rad (latitude in radians)
    delta float;                   -- rad (solar declination)
    omega_s float;                 -- rad (sunset hour angle)
    D_r float;                     -- dimless (inverse relative distance)
    R_a float;                     -- MJ/m²/day (extraterrestrial radiation)
    z float;                       -- m (elevation)
    R_so float;                    -- MJ/m²/day (clear-sky radiation)
    e_a float;                     -- kPa (actual vapour pressure)
    tmin_k float;                  -- K (minimum temperature)
    tmax_k float;                  -- K (maximum temperature)
    R_s float;                     -- MJ/m²/day (solar radiation)
    R_ln float;                    -- MJ/m²/day (net longwave radiation)
BEGIN
    -- Convert latitude to radians
    phi := latitude * (PI() / 180);
    
    -- Solar declination [FAO-56 Eq.24]
    delta := 0.409 * SIN((2 * PI() / 365 * day_of_year) - 1.39);
    
    -- Sunset hour angle [FAO-56 Eq.25]
    omega_s := ACOS(-TAN(phi) * TAN(delta));    
    
    -- Inverse relative distance [FAO-56 Eq.23]
    D_r := 1 + 0.033 * COS((2 * PI() / 365) * day_of_year);    
    
    -- Extraterrestrial radiation [FAO-56 Eq.21]
    R_a := extraterrestrial_radiation(D_r, omega_s, phi, delta);
    
    -- Elevation
    z := elevation;
    
    -- Clear-sky radiation [FAO-56 Eq.37]
    R_so := clearsky_radiation(R_a, z);
    
    -- Actual vapour pressure [FAO-56 Eq.48]
    e_a := saturation_vapour_pressure(tmin);    
    
    -- Temperature in Kelvin
    tmin_k := tmin + 273.16;
    tmax_k := tmax + 273.16;
    
    -- Solar radiation
    R_s := solar_radiation(tmin, tmax, R_a, inland_station);
   
    -- Net longwave radiation [FAO-56 Eq.39]
    R_ln := net_longwave_radiation(tmin_k, tmax_k, R_s, R_so, e_a);
    
    RETURN R_ln;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ms_net_radiation(
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    latitude float,                -- ° (latitude in decimal degrees)
    elevation float,               -- m (station elevation)
    day_of_year integer,           -- 1-366 (day of year)
    inland_station boolean DEFAULT TRUE
) RETURNS float AS $$              -- MJ/m²/day (net radiation)
DECLARE
    R_s float;                     -- MJ/m²/day (solar radiation)
    R_sn float;                    -- MJ/m²/day (net shortwave radiation)
    R_ln float;                    -- MJ/m²/day (net longwave radiation)
    R_n float;                     -- MJ/m²/day (net radiation)
BEGIN 
    -- Net shortwave radiation [FAO-56 Eq.38]
    R_sn := ms_net_shortwave_radiation(tmin, tmax, latitude, day_of_year, inland_station);
    
    -- Net longwave radiation for Automatic Stw[FAO-56 Eq.39]
    R_ln := ms_net_longwave_radiation(tmin, tmax, latitude, elevation, day_of_year, inland_station);
    
    -- Net radiation [FAO-56 Eq.40]
    R_n := net_radiation(R_sn, R_ln);
    RETURN R_n;
END;
$$ LANGUAGE plpgsql;

-- Hargreaves-Samani for Manual Stations
CREATE OR REPLACE FUNCTION ms_hargreaves_samani_evapotranspiration(
    alpha float,
    beta float,
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    latitude float,                -- ° (latitude in decimal degrees)
    day_of_year integer            -- 1-366 (day of year)
) RETURNS float AS $$              --
DECLARE
    D_r float;                     -- Dimensionless (inverse relative Earth-Sun distance) [FAO-56 Eq.23]
    omega_s float;                 -- Radians (sunset hour angle) [FAO-56 Eq.25]
    phi float;                     -- Radians (latitude) 
    delta float;                   -- Radians (solar declination) [FAO-56 Eq.24]
    R_a float;                     -- MJ/m²/day (extraterrestrial radiation)
    T float;                       -- °C (mean daily air temperature at 2m)
    ET_0 float;
BEGIN
    -- Convert latitude to radians
    phi := latitude * (PI() / 180);
    
    -- Solar declination [FAO-56 Eq.24]
    delta := 0.409 * SIN((2 * PI() / 365 * day_of_year) - 1.39);
    
    -- Sunset hour angle [FAO-56 Eq.25]
    omega_s := ACOS(-TAN(phi) * TAN(delta));    
    
    -- Inverse relative distance [FAO-56 Eq.23]
    D_r := 1 + 0.033 * COS((2 * PI() / 365) * day_of_year);    
    
    -- Extraterrestrial radiation [FAO-56 Eq.21]
    R_a := extraterrestrial_radiation(D_r, omega_s, phi, delta);

    -- Mean daily air temperature at 2m
    T := (tmin + tmax) / 2;

    ET_0 := hargreaves_samani_evapotranspiration(alpha, beta, tmin, tmax, T, R_a);
    RETURN ET_0;
END;
$$ LANGUAGE plpgsql;

-- Automatic Station Functions

-- Allen et al. (1998), FAO-56 (Equation 38).
CREATE OR REPLACE FUNCTION as_net_shortwave_radiation(
    solar_rad float,               -- W/m²y (solar radiation)
    albedo float DEFAULT 0.23      -- dimensionless (surface albedo)
) RETURNS float AS $$              -- MJ/m²/day (net shortwave radiation)
DECLARE
    R_s float;                     -- MJ/m²y (solar radiation)
    R_sn float;                    -- MJ/m²/day (net shortwave radiation)
BEGIN
    -- Solar radiation
    -- Convert W/m² to MJ/m²/day
    R_s := solar_rad * 0.0036;

    R_sn := (1 - albedo) * R_s;
    RETURN R_sn;
END;
$$ LANGUAGE plpgsql;

-- Net Longwave Radiation for Automatic Stations
CREATE OR REPLACE FUNCTION as_net_longwave_radiation(
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    latitude float,                -- ° (latitude in decimal degrees)
    elevation float,               -- m (station elevation)
    solar_rad float,               -- W/m² (measured solar radiation)
    rh float,                      -- % (relative humidity)
    day_of_year integer            -- 1-366 (day of year)
) RETURNS float AS $$              -- MJ/m²/day (net radiation)
DECLARE
    phi float;                     -- rad (latitude in radians)
    delta float;                   -- rad (solar declination)
    omega_s float;                 -- rad (sunset hour angle)
    D_r float;                     -- dimless (inverse relative distance)
    R_a float;                     -- MJ/m²/day (extraterrestrial radiation)
    z float;                       -- m (elevation)
    R_so float;                    -- MJ/m²/day (clear-sky radiation)
    e_a float;                     -- kPa (actual vapour pressure)
    tmin_k float;                  -- K (minimum temperature)
    tmax_k float;                  -- K (maximum temperature)
    R_s float;                     -- MJ/m²/day (solar radiation)
    R_ln float;                    -- MJ/m²/day (net longwave radiation)
BEGIN
    -- Convert latitude to radians
    phi := latitude * (PI() / 180);
    
    -- Solar declination [FAO-56 Eq.24]
    delta := 0.409 * SIN((2 * PI() / 365 * day_of_year) - 1.39);
    
    -- Sunset hour angle [FAO-56 Eq.25]
    omega_s := ACOS(-TAN(phi) * TAN(delta));    
    
    -- Inverse relative distance [FAO-56 Eq.23]
    D_r := 1 + 0.033 * COS((2 * PI() / 365) * day_of_year);    
    
    -- Extraterrestrial radiation [FAO-56 Eq.21]
    R_a := extraterrestrial_radiation(D_r, omega_s, phi, delta);
    
    -- Elevation
    z := elevation;
    
    -- Clear-sky radiation [FAO-56 Eq.37]
    R_so := clearsky_radiation(R_a, z);
    
    -- Actual vapour pressure [FAO-56 Eq.19]
    e_a := actual_vapour_pressure(tmin, tmax, rh);
    
    -- Temperature in Kelvin
    tmin_k := tmin + 273.16;
    tmax_k := tmax + 273.16;
    
    -- Convert solar radiation of W/m² to MJ/m²/day
    R_s := solar_rad * 0.0036;
   
    -- Net longwave radiation [FAO-56 Eq.39]
    R_ln := net_longwave_radiation(tmin_k, tmax_k, R_s, R_so, e_a);
    
    RETURN R_ln;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION as_net_radiation(
    tmax float,                    -- °C (daily maximum temperature)
    tmin float,                    -- °C (daily minimum temperature)
    latitude float,                -- ° (latitude in decimal degrees)
    elevation float,               -- m (station elevation)
    solar_rad float,               -- W/m² (measured solar radiation)
    rh float,                      -- % (relative humidity)
    day_of_year integer            -- 1-366 (day of year)
) RETURNS float AS $$              -- MJ/m²/day (net radiation)
DECLARE
    R_s float;                     -- MJ/m²/day (solar radiation)
    R_sn float;                    -- MJ/m²/day (net shortwave radiation)
    R_ln float;                    -- MJ/m²/day (net longwave radiation)
    R_n float;                     -- MJ/m²/day (net radiation)
BEGIN 
    -- Net shortwave radiation [FAO-56 Eq.38]
    R_sn := as_net_shortwave_radiation(solar_rad);
    
    -- Net longwave radiation for Automatic Stations [FAO-56 Eq.39]
    R_ln := as_net_longwave_radiation(tmax,tmin,latitude,elevation,solar_rad,rh, day_of_year);
    
    -- Net radiation [FAO-56 Eq.40]
    R_n := net_radiation(R_sn, R_ln);
    RETURN R_n;
END;
$$ LANGUAGE plpgsql;


-- Hargreaves-Samani for Automatic Stations
CREATE OR REPLACE FUNCTION as_hargreaves_samani_evapotranspiration(
    alpha float,
    beta float,
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    latitude float,                -- ° (latitude in decimal degrees)
    day_of_year integer            -- 1-366 (day of year)
) RETURNS float AS $$              --
DECLARE
    D_r float;                     -- Dimensionless (inverse relative Earth-Sun distance) [FAO-56 Eq.23]
    omega_s float;                 -- Radians (sunset hour angle) [FAO-56 Eq.25]
    phi float;                     -- Radians (latitude) 
    delta float;                   -- Radians (solar declination) [FAO-56 Eq.24]
    R_a float;                     -- MJ/m²/day (extraterrestrial radiation)
    T float;                       -- °C (mean daily air temperature at 2m)
    ET_0 float;
BEGIN
    -- Convert latitude to radians
    phi := latitude * (PI() / 180);
    
    -- Solar declination [FAO-56 Eq.24]
    delta := 0.409 * SIN((2 * PI() / 365 * day_of_year) - 1.39);
    
    -- Sunset hour angle [FAO-56 Eq.25]
    omega_s := ACOS(-TAN(phi) * TAN(delta));    
    
    -- Inverse relative distance [FAO-56 Eq.23]
    D_r := 1 + 0.033 * COS((2 * PI() / 365) * day_of_year);    
    
    -- Extraterrestrial radiation [FAO-56 Eq.21]
    R_a := extraterrestrial_radiation(D_r, omega_s, phi, delta);

    -- Mean daily air temperature at 2m
    T := (tmin + tmax) / 2;

    ET_0 := hargreaves_samani_evapotranspiration(alpha, beta, tmin, tmax, T, R_a);
    RETURN ET_0;
END;
$$ LANGUAGE plpgsql;

-- Penman-Monteith for Automatic Stations
CREATE OR REPLACE FUNCTION as_penman_monteith_evapotranspiration(
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    atm_press float,               -- kPa (atmospheric pressure)
    wind_spd float,                -- Knots (wind speed)
    solar_rad float,               -- W/m² (solar radiation)
    rh float,                      -- % (relative humidity)
    latitude float,                -- ° (latitude in decimal degrees)
    elevation float,               -- m (station elevation)
    day_of_year integer            -- 1-366 (day of year)
) RETURNS float AS $$              -- mm/day (reference evapotranspiration)
DECLARE
    height float;                  -- m (station height in meters)
    T float;                       -- °C (mean daily temperature)
    u_2 float;                     -- m/s (wind speed at 2m)
    e_a float;                     -- kPa (actual vapour pressure)
    e_tmin float;                  -- kPa (saturation VP at tmin)
    e_tmax float;                  -- kPa (saturation VP at tmax)
    e_s float;                     -- kPa (mean saturation VP)
    R_s float;                     -- MJ/m²/day (solar radiation)
    R_n float;                     -- MJ/m²/day (net radiation)
    G float;                       -- MJ/m²/day (soil heat flux)
    delta float;                   -- kPa/°C (slope of VP curve)
    gamma float;                   -- kPa/°C (psychrometric constant)
    ET_0 float;                    -- mm/day (reference ET)
BEGIN
    -- Mean temperature
    T := (tmin + tmax) / 2;
    
    -- Convert Knots to m/s
    u_2 := wind_spd * 0.514;

    -- param uz: wind speed at height z
    -- param z: height in meters
    -- u_2 := uz * (4.87/(log(67.8 * z - 5.42)))
    
    -- height := 10;
    -- u_2 := u_2 * (4.87/(log(67.8 * height - 5.42)));
       
    -- Actual vapour pressure [FAO-56 Eq.19]
    e_a := actual_vapour_pressure(tmin, tmax, rh);
    
    -- Saturation vapour pressures [FAO-56 Eq.11]
    e_tmin := saturation_vapour_pressure(tmin);
    e_tmax := saturation_vapour_pressure(tmax);
    
    -- Mean saturation vapour pressure [FAO-56 Eq.12]
    e_s := (e_tmin + e_tmax) / 2;
    
    -- Solar radiation
    -- Convert W/m² to MJ/m²/day
    R_s := solar_rad * 0.0036;
    
    -- Net radiation
    R_n := as_net_radiation(tmin, tmax, latitude, elevation, solar_rad, rh, day_of_year);
    
    -- Soil heat flux [FAO-56 Eqs.45-46]
    G := soil_heat_flux(R_s, R_n);
    
    -- Slope of saturation VP curve [FAO-56 Eq.13]
    delta := slope_saturation_vapour_pressure_curve(T);
    
    -- Psychrometric constant [FAO-56 Eq.8]
    gamma := 0.000665 * atm_press;
    
    -- Reference evapotranspiration [FAO-56 Eq.6]
    ET_0 := penman_monteith_evapotranspiration(R_n, G, T, u_2, e_s, e_a, delta, gamma);
    
    RETURN ET_0;
END;
$$ LANGUAGE plpgsql;