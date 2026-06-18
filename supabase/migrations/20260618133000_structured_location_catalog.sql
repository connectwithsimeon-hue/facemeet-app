-- Structured location catalog for country -> region -> place selection.
-- This is the durable layer behind discovery ranking and future onboarding pickers.

CREATE TABLE IF NOT EXISTS public.location_countries (
  code TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  normalized_name TEXT NOT NULL UNIQUE,
  enabled BOOLEAN NOT NULL DEFAULT true,
  sort_order INTEGER NOT NULL DEFAULT 1000,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.location_regions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  country_code TEXT NOT NULL REFERENCES public.location_countries(code) ON DELETE CASCADE,
  region_code TEXT,
  name TEXT NOT NULL,
  normalized_name TEXT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT true,
  sort_order INTEGER NOT NULL DEFAULT 1000,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(country_code, region_code),
  UNIQUE(country_code, normalized_name)
);

CREATE TABLE IF NOT EXISTS public.location_places (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  country_code TEXT NOT NULL REFERENCES public.location_countries(code) ON DELETE CASCADE,
  region_id UUID REFERENCES public.location_regions(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  normalized_name TEXT NOT NULL,
  place_type TEXT NOT NULL DEFAULT 'city',
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  population BIGINT,
  geoname_id BIGINT UNIQUE,
  enabled BOOLEAN NOT NULL DEFAULT true,
  sort_order INTEGER NOT NULL DEFAULT 1000,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(country_code, region_id, normalized_name)
);

CREATE TABLE IF NOT EXISTS public.location_place_aliases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  place_id UUID NOT NULL REFERENCES public.location_places(id) ON DELETE CASCADE,
  country_code TEXT REFERENCES public.location_countries(code) ON DELETE CASCADE,
  region_id UUID REFERENCES public.location_regions(id) ON DELETE CASCADE,
  alias TEXT NOT NULL,
  alias_key TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'facemeet',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(place_id, alias_key, country_code, region_id)
);

CREATE INDEX IF NOT EXISTS idx_location_regions_country_enabled
  ON public.location_regions(country_code, enabled, sort_order, name);

CREATE INDEX IF NOT EXISTS idx_location_places_country_region_enabled
  ON public.location_places(country_code, region_id, enabled, sort_order, population DESC NULLS LAST, name);

CREATE INDEX IF NOT EXISTS idx_location_places_normalized
  ON public.location_places(country_code, normalized_name);

CREATE INDEX IF NOT EXISTS idx_location_place_aliases_lookup
  ON public.location_place_aliases(country_code, region_id, alias_key);

CREATE INDEX IF NOT EXISTS idx_location_place_aliases_place
  ON public.location_place_aliases(place_id);

ALTER TABLE public.location_aliases
  ADD COLUMN IF NOT EXISTS canonical_place_id UUID REFERENCES public.location_places(id) ON DELETE SET NULL;

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS canonical_place_id UUID REFERENCES public.location_places(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_users_canonical_place_id
  ON public.users(canonical_place_id);

INSERT INTO public.location_countries (code, name, normalized_name, sort_order)
VALUES
  ('NG', 'Nigeria', public.location_alias_key('Nigeria'), 10),
  ('CA', 'Canada', public.location_alias_key('Canada'), 20),
  ('US', 'United States', public.location_alias_key('United States'), 30)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    normalized_name = EXCLUDED.normalized_name,
    sort_order = EXCLUDED.sort_order,
    enabled = true;

WITH regions(country_code, region_code, name, sort_order) AS (
  VALUES
    -- Nigeria
    ('NG', 'AB', 'Abia', 100),
    ('NG', 'AD', 'Adamawa', 110),
    ('NG', 'AK', 'Akwa Ibom', 120),
    ('NG', 'AN', 'Anambra', 130),
    ('NG', 'BA', 'Bauchi', 140),
    ('NG', 'BY', 'Bayelsa', 150),
    ('NG', 'BE', 'Benue', 160),
    ('NG', 'BO', 'Borno', 170),
    ('NG', 'CR', 'Cross River', 180),
    ('NG', 'DE', 'Delta', 190),
    ('NG', 'EB', 'Ebonyi', 200),
    ('NG', 'ED', 'Edo', 210),
    ('NG', 'EK', 'Ekiti', 220),
    ('NG', 'EN', 'Enugu', 230),
    ('NG', 'FC', 'FCT', 10),
    ('NG', 'GO', 'Gombe', 240),
    ('NG', 'IM', 'Imo', 250),
    ('NG', 'JI', 'Jigawa', 260),
    ('NG', 'KD', 'Kaduna', 270),
    ('NG', 'KN', 'Kano', 280),
    ('NG', 'KT', 'Katsina', 290),
    ('NG', 'KE', 'Kebbi', 300),
    ('NG', 'KO', 'Kogi', 310),
    ('NG', 'KW', 'Kwara', 320),
    ('NG', 'LA', 'Lagos', 20),
    ('NG', 'NA', 'Nasarawa', 330),
    ('NG', 'NI', 'Niger', 340),
    ('NG', 'OG', 'Ogun', 350),
    ('NG', 'ON', 'Ondo', 360),
    ('NG', 'OS', 'Osun', 370),
    ('NG', 'OY', 'Oyo', 380),
    ('NG', 'PL', 'Plateau', 390),
    ('NG', 'RI', 'Rivers', 400),
    ('NG', 'SO', 'Sokoto', 410),
    ('NG', 'TA', 'Taraba', 420),
    ('NG', 'YO', 'Yobe', 430),
    ('NG', 'ZA', 'Zamfara', 440),
    -- Canada
    ('CA', 'AB', 'Alberta', 100),
    ('CA', 'BC', 'British Columbia', 20),
    ('CA', 'MB', 'Manitoba', 120),
    ('CA', 'NB', 'New Brunswick', 130),
    ('CA', 'NL', 'Newfoundland and Labrador', 140),
    ('CA', 'NS', 'Nova Scotia', 150),
    ('CA', 'NT', 'Northwest Territories', 160),
    ('CA', 'NU', 'Nunavut', 170),
    ('CA', 'ON', 'Ontario', 10),
    ('CA', 'PE', 'Prince Edward Island', 180),
    ('CA', 'QC', 'Quebec', 30),
    ('CA', 'SK', 'Saskatchewan', 190),
    ('CA', 'YT', 'Yukon', 200),
    -- United States launch/support examples
    ('US', 'TX', 'Texas', 10),
    ('US', 'NY', 'New York', 20),
    ('US', 'CA', 'California', 30)
)
INSERT INTO public.location_regions (country_code, region_code, name, normalized_name, sort_order)
SELECT country_code, region_code, name, public.location_alias_key(name), sort_order
FROM regions
ON CONFLICT (country_code, region_code) DO UPDATE
SET name = EXCLUDED.name,
    normalized_name = EXCLUDED.normalized_name,
    sort_order = EXCLUDED.sort_order,
    enabled = true;

CREATE OR REPLACE FUNCTION public.seed_location_place(
  p_country_code TEXT,
  p_region_code TEXT,
  p_name TEXT,
  p_place_type TEXT DEFAULT 'city',
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
  v_place_id UUID;
  v_alias TEXT;
BEGIN
  SELECT id INTO v_region_id
  FROM public.location_regions
  WHERE country_code = upper(p_country_code)
    AND region_code = p_region_code
  LIMIT 1;

  INSERT INTO public.location_places (
    country_code,
    region_id,
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
    p_name,
    public.location_alias_key(p_name),
    p_place_type,
    p_latitude,
    p_longitude,
    p_population,
    p_sort_order
  )
  ON CONFLICT (country_code, region_id, normalized_name) DO UPDATE
  SET name = EXCLUDED.name,
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

SELECT public.seed_location_place('NG', 'FC', 'Abuja', 'city', 9.0765, 7.3986, 1235880, 10, ARRAY[
  'ABJ', 'Abj', 'FCT', 'FCT-Abuja', 'Abuja-FCT', 'Abuja FCT',
  'Federal Capital Territory', 'Federal Capital Territory Abuja'
]);

SELECT public.seed_location_place('NG', 'LA', 'Lagos', 'city', 6.5244, 3.3792, 15388000, 20, ARRAY[
  'Lag', 'Lasgidi', 'Eko', 'Lagos State'
]);

SELECT public.seed_location_place('NG', 'LA', 'Somolu', 'local_area', 6.5392, 3.3840, NULL, 30, ARRAY[
  'Shomolu', 'Somolu Lagos', 'Shomolu Lagos'
]);

SELECT public.seed_location_place('NG', 'LA', 'Lekki', 'local_area', 6.4698, 3.5852, NULL, 40, ARRAY[
  'Lekki Phase 1', 'Lekki 1', 'Lekki Lagos'
]);

SELECT public.seed_location_place('NG', 'LA', 'Victoria Island', 'local_area', 6.4281, 3.4219, NULL, 50, ARRAY[
  'VI', 'V.I.', 'Victoria Island Lagos'
]);

SELECT public.seed_location_place('NG', 'RI', 'Port Harcourt', 'city', 4.8156, 7.0498, NULL, 60, ARRAY[
  'PH', 'PHC', 'Pitakwa', 'Port Harcourt Rivers'
]);

SELECT public.seed_location_place('NG', 'OY', 'Ibadan', 'city', 7.3775, 3.9470, NULL, 70, ARRAY[
  'Ibadan Oyo'
]);

SELECT public.seed_location_place('CA', 'ON', 'Toronto', 'city', 43.6532, -79.3832, 2794356, 10, ARRAY[
  'GTA', 'Greater Toronto Area', 'Toronto ON', 'Toronto Ontario'
]);

SELECT public.seed_location_place('CA', 'BC', 'Vancouver', 'city', 49.2827, -123.1207, 662248, 20, ARRAY[
  'Vancouver BC', 'Van City'
]);

SELECT public.seed_location_place('CA', 'QC', 'Montreal', 'city', 45.5017, -73.5673, 1762949, 30, ARRAY[
  'Montréal', 'Montreal QC', 'Mtl'
]);

SELECT public.seed_location_place('CA', 'AB', 'Calgary', 'city', 51.0447, -114.0719, 1306784, 40, ARRAY[
  'Calgary AB'
]);

SELECT public.seed_location_place('CA', 'AB', 'Edmonton', 'city', 53.5461, -113.4938, 1010899, 50, ARRAY[
  'Edmonton AB'
]);

SELECT public.seed_location_place('US', 'TX', 'Dallas', 'city', 32.7767, -96.7970, 1302868, 10, ARRAY[
  'DFW', 'Dallas TX', 'Dallas-Fort Worth'
]);

UPDATE public.location_aliases la
SET canonical_place_id = lp.id
FROM public.location_places lp
LEFT JOIN public.location_regions lr ON lr.id = lp.region_id
WHERE la.canonical_place_id IS NULL
  AND lp.country_code = la.canonical_country
  AND public.location_alias_key(lp.name) = public.location_alias_key(la.canonical_city)
  AND (
    la.canonical_state_region IS NULL
    OR lr.normalized_name = public.location_alias_key(la.canonical_state_region)
    OR lr.region_code = la.canonical_state_region
  );

CREATE OR REPLACE FUNCTION public.search_locations(
  p_query TEXT DEFAULT '',
  p_country_code TEXT DEFAULT NULL,
  p_region_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
  place_id UUID,
  country_code TEXT,
  country_name TEXT,
  region_id UUID,
  region_code TEXT,
  region_name TEXT,
  place_name TEXT,
  place_type TEXT,
  display_name TEXT,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  population BIGINT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH input AS (
    SELECT
      public.location_alias_key(p_query) AS q,
      NULLIF(upper(btrim(COALESCE(p_country_code, ''))), '') AS country_code,
      p_region_id AS region_id,
      GREATEST(1, LEAST(COALESCE(p_limit, 20), 50)) AS max_rows
  ),
  ranked AS (
    SELECT DISTINCT ON (lp.id)
      lp.id AS place_id,
      lp.country_code,
      lc.name AS country_name,
      lr.id AS region_id,
      lr.region_code,
      lr.name AS region_name,
      lp.name AS place_name,
      lp.place_type,
      CONCAT_WS(', ', lp.name, lr.name, lc.name) AS display_name,
      lp.latitude,
      lp.longitude,
      lp.population,
      CASE
        WHEN i.q IS NULL THEN 10
        WHEN lpa.alias_key = i.q THEN 100
        WHEN lp.normalized_name = i.q THEN 95
        WHEN lpa.alias_key LIKE i.q || '%' THEN 80
        WHEN lp.normalized_name LIKE i.q || '%' THEN 75
        WHEN lpa.alias_key LIKE '%' || i.q || '%' THEN 55
        WHEN lp.normalized_name LIKE '%' || i.q || '%' THEN 50
        ELSE 0
      END AS match_rank
    FROM public.location_places lp
    JOIN public.location_countries lc ON lc.code = lp.country_code
    LEFT JOIN public.location_regions lr ON lr.id = lp.region_id
    CROSS JOIN input i
    LEFT JOIN public.location_place_aliases lpa ON lpa.place_id = lp.id
    WHERE lp.enabled = true
      AND lc.enabled = true
      AND (lr.id IS NULL OR lr.enabled = true)
      AND (i.country_code IS NULL OR lp.country_code = i.country_code)
      AND (i.region_id IS NULL OR lp.region_id = i.region_id)
      AND (
        i.q IS NULL
        OR lp.normalized_name LIKE '%' || i.q || '%'
        OR lpa.alias_key LIKE '%' || i.q || '%'
      )
    ORDER BY lp.id, match_rank DESC
  )
  SELECT
    place_id,
    country_code,
    country_name,
    region_id,
    region_code,
    region_name,
    place_name,
    place_type,
    display_name,
    latitude,
    longitude,
    population
  FROM ranked
  ORDER BY
    match_rank DESC,
    population DESC NULLS LAST,
    display_name ASC
  LIMIT (SELECT max_rows FROM input);
$$;

CREATE OR REPLACE FUNCTION public.resolve_location(
  p_city TEXT,
  p_state_region TEXT DEFAULT NULL,
  p_country TEXT DEFAULT NULL,
  p_metro_area TEXT DEFAULT NULL
)
RETURNS TABLE (
  place_id UUID,
  city TEXT,
  state_region TEXT,
  country TEXT,
  metro_area TEXT,
  location_canonical_key TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH normalized AS (
    SELECT
      public.location_alias_key(p_city) AS city_key,
      public.location_alias_key(CONCAT_WS(' ', p_city, p_state_region)) AS city_state_key,
      public.location_alias_key(CONCAT_WS(' ', p_state_region, p_city)) AS state_city_key,
      public.location_alias_key(p_metro_area) AS metro_key,
      public.canonical_country_code(p_country) AS country_code,
      public.location_alias_key(p_state_region) AS state_key
  ),
  region_match AS (
    SELECT lr.id
    FROM public.location_regions lr
    CROSS JOIN normalized n
    WHERE (n.country_code IS NULL OR lr.country_code = n.country_code)
      AND (
        lr.normalized_name = n.state_key
        OR public.location_alias_key(lr.region_code) = n.state_key
      )
    LIMIT 1
  ),
  alias_match AS (
    SELECT
      lp.id,
      lp.name AS city,
      lr.name AS state_region,
      lp.country_code AS country,
      COALESCE(lp.name, lp.normalized_name) AS metro_area,
      CONCAT_WS(':', public.location_alias_key(lp.country_code), public.location_alias_key(lr.name), public.location_alias_key(lp.name)) AS key_value,
      CASE
        WHEN lpa.alias_key = n.city_key THEN 1
        WHEN lpa.alias_key = n.city_state_key THEN 2
        WHEN lpa.alias_key = n.state_city_key THEN 3
        WHEN lpa.alias_key = n.metro_key THEN 4
        ELSE 9
      END AS rank_value
    FROM public.location_place_aliases lpa
    JOIN public.location_places lp ON lp.id = lpa.place_id
    LEFT JOIN public.location_regions lr ON lr.id = lp.region_id
    CROSS JOIN normalized n
    WHERE lp.enabled = true
      AND (n.country_code IS NULL OR lp.country_code = n.country_code)
      AND (
        NOT EXISTS (SELECT 1 FROM region_match)
        OR lp.region_id = (SELECT id FROM region_match)
      )
      AND lpa.alias_key IN (n.city_key, n.city_state_key, n.state_city_key, n.metro_key)
    ORDER BY rank_value ASC
    LIMIT 1
  )
  SELECT
    id AS place_id,
    city,
    state_region,
    country,
    metro_area,
    key_value AS location_canonical_key
  FROM alias_match;
$$;

DROP FUNCTION IF EXISTS public.canonicalize_location_parts(TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.canonicalize_location_parts(
  p_city TEXT,
  p_state_region TEXT,
  p_country TEXT,
  p_metro_area TEXT
)
RETURNS TABLE (
  city TEXT,
  state_region TEXT,
  country TEXT,
  metro_area TEXT,
  canonical_city TEXT,
  canonical_state_region TEXT,
  canonical_country TEXT,
  canonical_metro_area TEXT,
  location_canonical_key TEXT,
  canonical_place_id UUID
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_city TEXT := NULLIF(btrim(COALESCE(p_city, '')), '');
  v_state TEXT := NULLIF(btrim(COALESCE(p_state_region, '')), '');
  v_country TEXT := public.canonical_country_code(p_country);
  v_metro TEXT := NULLIF(btrim(COALESCE(p_metro_area, '')), '');
  v_resolved RECORD;
  v_alias public.location_aliases%ROWTYPE;
BEGIN
  SELECT *
  INTO v_resolved
  FROM public.resolve_location(v_city, v_state, v_country, v_metro)
  LIMIT 1;

  IF FOUND THEN
    city := v_resolved.city;
    state_region := v_resolved.state_region;
    country := v_resolved.country;
    metro_area := COALESCE(v_resolved.metro_area, v_resolved.city);
    canonical_city := v_resolved.city;
    canonical_state_region := v_resolved.state_region;
    canonical_country := v_resolved.country;
    canonical_metro_area := COALESCE(v_resolved.metro_area, v_resolved.city);
    location_canonical_key := v_resolved.location_canonical_key;
    canonical_place_id := v_resolved.place_id;
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT *
  INTO v_alias
  FROM public.location_aliases la
  WHERE la.alias_key IN (
    public.location_alias_key(v_city),
    public.location_alias_key(CONCAT_WS(' ', v_city, v_state)),
    public.location_alias_key(CONCAT_WS(' ', v_state, v_city)),
    public.location_alias_key(CONCAT_WS(' ', v_city, v_country)),
    public.location_alias_key(v_metro),
    public.location_alias_key(v_state)
  )
  ORDER BY CASE la.alias_key
    WHEN public.location_alias_key(v_city) THEN 1
    WHEN public.location_alias_key(CONCAT_WS(' ', v_city, v_state)) THEN 2
    WHEN public.location_alias_key(CONCAT_WS(' ', v_state, v_city)) THEN 3
    WHEN public.location_alias_key(CONCAT_WS(' ', v_city, v_country)) THEN 4
    WHEN public.location_alias_key(v_metro) THEN 5
    ELSE 6
  END
  LIMIT 1;

  IF FOUND THEN
    city := v_alias.canonical_city;
    state_region := v_alias.canonical_state_region;
    country := v_alias.canonical_country;
    metro_area := COALESCE(v_alias.canonical_metro_area, v_alias.canonical_city);
    canonical_city := v_alias.canonical_city;
    canonical_state_region := v_alias.canonical_state_region;
    canonical_country := v_alias.canonical_country;
    canonical_metro_area := COALESCE(v_alias.canonical_metro_area, v_alias.canonical_city);
    canonical_place_id := v_alias.canonical_place_id;
  ELSE
    city := v_city;
    state_region := v_state;
    country := v_country;
    metro_area := v_metro;
    canonical_city := v_city;
    canonical_state_region := v_state;
    canonical_country := v_country;
    canonical_metro_area := COALESCE(v_metro, v_city);
    canonical_place_id := NULL;
  END IF;

  location_canonical_key := CONCAT_WS(
    ':',
    public.location_alias_key(canonical_country),
    public.location_alias_key(canonical_state_region),
    public.location_alias_key(canonical_city)
  );

  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_user_canonical_location()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_location RECORD;
BEGIN
  SELECT *
  INTO v_location
  FROM public.canonicalize_location_parts(
    NEW.city,
    NEW.state_region,
    NEW.country,
    NEW.metro_area
  );

  NEW.city := v_location.city;
  NEW.state_region := v_location.state_region;
  NEW.country := v_location.country;
  NEW.metro_area := v_location.metro_area;
  NEW.canonical_city := v_location.canonical_city;
  NEW.canonical_state_region := v_location.canonical_state_region;
  NEW.canonical_country := v_location.canonical_country;
  NEW.canonical_metro_area := v_location.canonical_metro_area;
  NEW.location_canonical_key := v_location.location_canonical_key;
  NEW.canonical_place_id := v_location.canonical_place_id;

  RETURN NEW;
END;
$$;

UPDATE public.users u
SET city = normalized.city,
    state_region = normalized.state_region,
    country = normalized.country,
    metro_area = normalized.metro_area,
    canonical_city = normalized.canonical_city,
    canonical_state_region = normalized.canonical_state_region,
    canonical_country = normalized.canonical_country,
    canonical_metro_area = normalized.canonical_metro_area,
    location_canonical_key = normalized.location_canonical_key,
    canonical_place_id = normalized.canonical_place_id
FROM (
  SELECT
    existing.id,
    normalized.city,
    normalized.state_region,
    normalized.country,
    normalized.metro_area,
    normalized.canonical_city,
    normalized.canonical_state_region,
    normalized.canonical_country,
    normalized.canonical_metro_area,
    normalized.location_canonical_key,
    normalized.canonical_place_id
  FROM public.users existing
  CROSS JOIN LATERAL public.canonicalize_location_parts(
    existing.city,
    existing.state_region,
    existing.country,
    existing.metro_area
  ) AS normalized
) AS normalized
WHERE u.id = normalized.id;

DROP FUNCTION IF EXISTS public.seed_location_place(
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

GRANT SELECT ON public.location_countries TO anon, authenticated;
GRANT SELECT ON public.location_regions TO anon, authenticated;
GRANT SELECT ON public.location_places TO anon, authenticated;
GRANT SELECT ON public.location_place_aliases TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_locations(TEXT, TEXT, UUID, INTEGER) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_location(TEXT, TEXT, TEXT, TEXT) TO authenticated;
