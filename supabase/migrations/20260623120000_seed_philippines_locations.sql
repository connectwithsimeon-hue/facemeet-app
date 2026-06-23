-- Seed Philippines into the backend-driven FaceMeet Location Picker catalog.
-- This is data-only and idempotent: safe to run more than once.

CREATE OR REPLACE FUNCTION public.seed_location_place_for_ph_seed(
  p_country_code TEXT,
  p_region_code TEXT,
  p_name TEXT,
  p_place_type TEXT DEFAULT 'city',
  p_parent_name TEXT DEFAULT NULL,
  p_latitude DOUBLE PRECISION DEFAULT NULL,
  p_longitude DOUBLE PRECISION DEFAULT NULL,
  p_population BIGINT DEFAULT NULL,
  p_sort_order INTEGER DEFAULT 1000,
  p_aliases TEXT[] DEFAULT ARRAY[]::TEXT[]
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_region_id UUID;
  v_parent_place_id UUID;
  v_place_id UUID;
  v_alias TEXT;
BEGIN
  SELECT id INTO v_region_id
  FROM public.location_regions
  WHERE country_code = upper(p_country_code)
    AND region_code = p_region_code
  LIMIT 1;

  IF p_parent_name IS NOT NULL THEN
    SELECT id INTO v_parent_place_id
    FROM public.location_places
    WHERE country_code = upper(p_country_code)
      AND region_id IS NOT DISTINCT FROM v_region_id
      AND normalized_name = public.location_alias_key(p_parent_name)
      AND place_type = 'city'
    LIMIT 1;
  END IF;

  INSERT INTO public.location_places (
    country_code,
    region_id,
    parent_place_id,
    name,
    normalized_name,
    place_type,
    latitude,
    longitude,
    population,
    sort_order
  )
  VALUES (
    upper(p_country_code),
    v_region_id,
    v_parent_place_id,
    p_name,
    public.location_alias_key(p_name),
    p_place_type,
    p_latitude,
    p_longitude,
    p_population,
    p_sort_order
  )
  ON CONFLICT (country_code, region_id, normalized_name) DO UPDATE
  SET parent_place_id = COALESCE(EXCLUDED.parent_place_id, public.location_places.parent_place_id),
      name = EXCLUDED.name,
      place_type = EXCLUDED.place_type,
      latitude = COALESCE(EXCLUDED.latitude, public.location_places.latitude),
      longitude = COALESCE(EXCLUDED.longitude, public.location_places.longitude),
      population = COALESCE(EXCLUDED.population, public.location_places.population),
      sort_order = EXCLUDED.sort_order,
      enabled = true
  RETURNING id INTO v_place_id;

  INSERT INTO public.location_place_aliases (
    place_id,
    country_code,
    region_id,
    alias,
    alias_key,
    source
  )
  VALUES (
    v_place_id,
    upper(p_country_code),
    v_region_id,
    p_name,
    public.location_alias_key(p_name),
    'canonical_name'
  )
  ON CONFLICT (place_id, alias_key, country_code, region_id) DO NOTHING;

  FOREACH v_alias IN ARRAY COALESCE(p_aliases, ARRAY[]::TEXT[]) LOOP
    IF public.location_alias_key(v_alias) IS NOT NULL THEN
      INSERT INTO public.location_place_aliases (
        place_id,
        country_code,
        region_id,
        alias,
        alias_key,
        source
      )
      VALUES (
        v_place_id,
        upper(p_country_code),
        v_region_id,
        v_alias,
        public.location_alias_key(v_alias),
        'facemeet_alias'
      )
      ON CONFLICT (place_id, alias_key, country_code, region_id) DO NOTHING;
    END IF;
  END LOOP;

  RETURN v_place_id;
END;
$$;

INSERT INTO public.location_countries (code, name, normalized_name, sort_order, enabled)
VALUES ('PH', 'Philippines', public.location_alias_key('Philippines'), 80, true)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    normalized_name = EXCLUDED.normalized_name,
    sort_order = EXCLUDED.sort_order,
    enabled = true;

WITH regions(country_code, region_code, name, sort_order) AS (
  VALUES
    ('PH', 'NCR', 'Metro Manila', 10),
    ('PH', 'CALABARZON', 'Calabarzon', 20),
    ('PH', 'CENTRAL_LUZON', 'Central Luzon', 30),
    ('PH', 'CENTRAL_VISAYAS', 'Central Visayas', 40),
    ('PH', 'DAVAO', 'Davao Region', 50),
    ('PH', 'WESTERN_VISAYAS', 'Western Visayas', 60),
    ('PH', 'NORTHERN_MINDANAO', 'Northern Mindanao', 70),
    ('PH', 'CAR', 'Cordillera Administrative Region', 80),
    ('PH', 'SOCCSKSARGEN', 'Soccsksargen', 90),
    ('PH', 'ZAMBOANGA_PENINSULA', 'Zamboanga Peninsula', 100)
)
INSERT INTO public.location_regions (country_code, region_code, name, normalized_name, sort_order, enabled)
SELECT country_code, region_code, name, public.location_alias_key(name), sort_order, true
FROM regions
ON CONFLICT (country_code, region_code) DO UPDATE
SET name = EXCLUDED.name,
    normalized_name = EXCLUDED.normalized_name,
    sort_order = EXCLUDED.sort_order,
    enabled = true;

-- Metro Manila / NCR
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Manila', 'city', NULL, 14.5995, 120.9842, 1846513, 10, ARRAY[
  'City of Manila', 'Manila Philippines', 'Metro Manila'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Quezon City', 'city', NULL, 14.6760, 121.0437, 2960048, 20, ARRAY[
  'QC', 'Q.C.', 'Quezon City Philippines'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Makati', 'city', NULL, 14.5547, 121.0244, 629616, 30, ARRAY[
  'Makati City', 'Makati Philippines'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Taguig', 'city', NULL, 14.5176, 121.0509, 886722, 40, ARRAY[
  'Taguig City', 'BGC', 'Bonifacio Global City'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Pasig', 'city', NULL, 14.5764, 121.0851, 803159, 50, ARRAY[
  'Pasig City', 'Ortigas'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Mandaluyong', 'city', NULL, 14.5794, 121.0359, 425758, 60, ARRAY[
  'Mandaluyong City'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Parañaque', 'city', NULL, 14.4793, 121.0198, 689992, 70, ARRAY[
  'Paranaque', 'Parañaque City', 'Paranaque City'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Pasay', 'city', NULL, 14.5378, 121.0014, 440656, 80, ARRAY[
  'Pasay City'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Muntinlupa', 'city', NULL, 14.4081, 121.0415, 543445, 90, ARRAY[
  'Muntinlupa City'
]);

-- Metro Manila local areas
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Bonifacio Global City', 'local_area', 'Taguig', 14.5503, 121.0503, NULL, 110, ARRAY[
  'BGC', 'The Fort', 'Fort Bonifacio'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Ortigas Center', 'local_area', 'Pasig', 14.5868, 121.0614, NULL, 120, ARRAY[
  'Ortigas', 'Ortigas Pasig'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Poblacion', 'local_area', 'Makati', 14.5657, 121.0316, NULL, 130, ARRAY[
  'Poblacion Makati', 'Makati Poblacion'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NCR', 'Alabang', 'local_area', 'Muntinlupa', 14.4230, 121.0437, NULL, 140, ARRAY[
  'Alabang Muntinlupa'
]);

-- Luzon / Visayas / Mindanao priority cities
SELECT public.seed_location_place_for_ph_seed('PH', 'CENTRAL_VISAYAS', 'Cebu City', 'city', NULL, 10.3157, 123.8854, 964169, 10, ARRAY[
  'Cebu', 'Cebu Philippines'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'DAVAO', 'Davao City', 'city', NULL, 7.1907, 125.4553, 1776949, 10, ARRAY[
  'Davao', 'Davao Philippines'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'CENTRAL_LUZON', 'Angeles', 'city', NULL, 15.1449, 120.5887, 462928, 10, ARRAY[
  'Angeles City', 'Angeles Pampanga'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'CENTRAL_LUZON', 'Mabalacat', 'city', NULL, 15.2229, 120.5740, 293244, 20, ARRAY[
  'Mabalacat City', 'Clark', 'Clark Pampanga', 'Clark Freeport'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'WESTERN_VISAYAS', 'Iloilo City', 'city', NULL, 10.7202, 122.5621, 457626, 10, ARRAY[
  'Iloilo', 'Iloilo Philippines'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'WESTERN_VISAYAS', 'Bacolod', 'city', NULL, 10.6765, 122.9509, 600783, 20, ARRAY[
  'Bacolod City'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'NORTHERN_MINDANAO', 'Cagayan de Oro', 'city', NULL, 8.4542, 124.6319, 728402, 10, ARRAY[
  'CDO', 'Cagayan de Oro City'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'CAR', 'Baguio', 'city', NULL, 16.4023, 120.5960, 366358, 10, ARRAY[
  'Baguio City'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'SOCCSKSARGEN', 'General Santos', 'city', NULL, 6.1164, 125.1716, 697315, 10, ARRAY[
  'GenSan', 'Gensan', 'General Santos City'
]);
SELECT public.seed_location_place_for_ph_seed('PH', 'ZAMBOANGA_PENINSULA', 'Zamboanga City', 'city', NULL, 6.9214, 122.0790, 977234, 10, ARRAY[
  'Zamboanga'
]);

DROP FUNCTION IF EXISTS public.seed_location_place_for_ph_seed(
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  DOUBLE PRECISION,
  DOUBLE PRECISION,
  BIGINT,
  INTEGER,
  TEXT[]
);
