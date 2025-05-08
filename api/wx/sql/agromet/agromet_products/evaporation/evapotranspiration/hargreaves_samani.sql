-- Allen et al. (1998), FAO-56 (Equation 21).
CREATE OR REPLACE FUNCTION extraterrestrial_radiation(
    latitude float,          -- degrees (°)
    day_of_year integer      -- (1-366)
) RETURNS float AS $$        -- MJ/m²/day
DECLARE
    solar_declination float; -- radians (rad)
    inverse_relative_earth_sun_distance float; -- dimensionless
    latitude_radians float;  -- radians (rad)
    sunset_hour_angle float; -- radians (rad)
    extraterrestrial_radiation float; -- MJ/m²/day
BEGIN
    solar_declination := 0.409 * SIN((2 * PI() / 365 * day_of_year) - 1.39);
    inverse_relative_earth_sun_distance := 1 + 0.033 * COS((2 * PI() / 365) * day_of_year);
    latitude_radians := PI() / 180 * latitude;
    sunset_hour_angle := ACOS(-TAN(latitude_radians) * TAN(solar_declination));
    
    extraterrestrial_radiation := 24 * 60 / PI() * 0.0820 * inverse_relative_earth_sun_distance * 
        (sunset_hour_angle * SIN(latitude_radians) * SIN(solar_declination) + 
         COS(latitude_radians) * COS(solar_declination) * SIN(sunset_hour_angle));
    
    RETURN extraterrestrial_radiation;
END;
$$ LANGUAGE plpgsql;


-- Hargreaves-Samani
CREATE OR REPLACE FUNCTION hargreaves_samani_evapotranspiration(
    alpha float,
    beta float,
    tmax float,              -- °C
    tmin float,              -- °C
    latitude float,
    day_of_year integer
) RETURNS float AS $$    -- kPa (saturation vapour pressure at T)
DECLARE
    extraterrestrial_rad float;
    tmean float;           -- °C
    evapotranspiration float;
BEGIN
    tmean := (tmax + tmin) / 2;
    extraterrestrial_rad := extraterrestrial_radiation(latitude, day_of_year);
    evapotranspiration := alpha * POWER((tmax - tmin), beta) * (tmean + 17.8) * extraterrestrial_rad * 0.408;
    RETURN evapotranspiration;
END;
$$ LANGUAGE plpgsql;