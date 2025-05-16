-- Allen et al. (1998), FAO-56 (Equation 21).
CREATE OR REPLACE FUNCTION extraterrestrial_radiation(
    D_r float,                     -- Dimensionless (inverse relative Earth-Sun distance) [FAO-56 Eq.23]
    omega_s float,                 -- Radians (sunset hour angle) [FAO-56 Eq.25]
    phi float,                     -- Radians (latitude) 
    delta float,                   -- Radians (solar declination) [FAO-56 Eq.24]
    G_sc float DEFAULT 0.0820      -- MJ/m²/min (solar constant) 
) RETURNS float AS $$              -- MJ/m²/day (daily extraterrestrial radiation)
DECLARE
    Ra float;                      -- MJ/m²/day (extraterrestrial radiation)
BEGIN
    Ra := ((24 * 60 )/ PI()) * G_sc * D_r * (
        omega_s * SIN(phi) * SIN(delta) + COS(phi) * COS(delta) * SIN(omega_s)
    );
    RETURN Ra;
END;
$$ LANGUAGE plpgsql;

-- Hargreaves-Samani
CREATE OR REPLACE FUNCTION hargreaves_samani_evapotranspiration(
    alpha float,
    beta float,
    tmin float,                    -- °C (daily minimum temperature)
    tmax float,                    -- °C (daily maximum temperature)
    R_a float,                     -- MJ/m²/day (extraterrestrial radiation)
    T float                        -- °C (mean daily air temperature at 2m)
) RETURNS float AS $$              -- 
DECLARE
    ET_0 float;
BEGIN
    ET_0 := alpha * POWER((tmax - tmin), beta) * (T + 17.8) * R_a * 0.408;
    RETURN ET_0;
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

    ET_0 := hargreaves_samani_evapotranspiration(alpha, beta, tmin, tmax, latitude, day_of_year);
    RETURN ET_0;
END;
$$ LANGUAGE plpgsql;