-- Location Picker v1: structured user location fields, parent places, and priority market seeds.

ALTER TABLE public.location_places
  ADD COLUMN IF NOT EXISTS parent_place_id UUID REFERENCES public.location_places(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_location_places_parent
  ON public.location_places(parent_place_id);

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS country_code TEXT REFERENCES public.location_countries(code) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS region_id UUID REFERENCES public.location_regions(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS city_place_id UUID REFERENCES public.location_places(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS area_place_id UUID REFERENCES public.location_places(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS location_display_name TEXT,
  ADD COLUMN IF NOT EXISTS location_updated_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_users_location_ids
  ON public.users(country_code, region_id, city_place_id, area_place_id);

CREATE OR REPLACE FUNCTION public.location_display_name(
  p_area_name TEXT,
  p_city_name TEXT,
  p_region_name TEXT,
  p_country_name TEXT
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CONCAT_WS(
    ', ',
    NULLIF(btrim(COALESCE(p_area_name, '')), ''),
    NULLIF(btrim(COALESCE(p_city_name, '')), ''),
    NULLIF(btrim(COALESCE(p_region_name, '')), ''),
    NULLIF(btrim(COALESCE(p_country_name, '')), '')
  );
$$;

CREATE OR REPLACE FUNCTION public.seed_location_place_v1(
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

INSERT INTO public.location_countries (code, name, normalized_name, sort_order)
VALUES
  ('GB', 'United Kingdom', public.location_alias_key('United Kingdom'), 40),
  ('GH', 'Ghana', public.location_alias_key('Ghana'), 50),
  ('ZA', 'South Africa', public.location_alias_key('South Africa'), 60),
  ('KE', 'Kenya', public.location_alias_key('Kenya'), 70)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    normalized_name = EXCLUDED.normalized_name,
    sort_order = EXCLUDED.sort_order,
    enabled = true;

WITH regions(country_code, region_code, name, sort_order) AS (
  VALUES
    -- US priority states/district
    ('US', 'GA', 'Georgia', 40),
    ('US', 'FL', 'Florida', 50),
    ('US', 'IL', 'Illinois', 60),
    ('US', 'DC', 'District of Columbia', 70),
    ('US', 'AZ', 'Arizona', 80),
    -- UK
    ('GB', 'ENG', 'England', 10),
    ('GB', 'SCT', 'Scotland', 20),
    ('GB', 'WLS', 'Wales', 30),
    ('GB', 'NIR', 'Northern Ireland', 40),
    -- Ghana
    ('GH', 'AA', 'Greater Accra', 10),
    ('GH', 'AS', 'Ashanti', 20),
    ('GH', 'WR', 'Western', 30),
    -- South Africa
    ('ZA', 'GT', 'Gauteng', 10),
    ('ZA', 'WC', 'Western Cape', 20),
    ('ZA', 'KZN', 'KwaZulu-Natal', 30),
    -- Kenya
    ('KE', 'NAI', 'Nairobi County', 10),
    ('KE', 'MOM', 'Mombasa County', 20),
    ('KE', 'KSM', 'Kisumu County', 30)
)
INSERT INTO public.location_regions (country_code, region_code, name, normalized_name, sort_order)
SELECT country_code, region_code, name, public.location_alias_key(name), sort_order
FROM regions
ON CONFLICT (country_code, region_code) DO UPDATE
SET name = EXCLUDED.name,
    normalized_name = EXCLUDED.normalized_name,
    sort_order = EXCLUDED.sort_order,
    enabled = true;

-- Nigeria priority cities
SELECT public.seed_location_place_v1('NG', 'FC', 'Abuja', 'city', NULL, 9.0765, 7.3986, 1235880, 10, ARRAY[
  'ABJ', 'FCT', 'Abuja FCT', 'ABUJA-FCT', 'FCT-Abuja', 'Abuja-FCT'
]);
SELECT public.seed_location_place_v1('NG', 'LA', 'Lagos', 'city', NULL, 6.5244, 3.3792, 15388000, 20, ARRAY[
  'Lag', 'Lasgidi', 'Eko', 'Lagos State'
]);
SELECT public.seed_location_place_v1('NG', 'RI', 'Port Harcourt', 'city', NULL, 4.8156, 7.0498, NULL, 30, ARRAY[
  'PH', 'PHC', 'Pitakwa'
]);
SELECT public.seed_location_place_v1('NG', 'OY', 'Ibadan', 'city', NULL, 7.3775, 3.9470, NULL, 40, ARRAY['Ibadan Oyo']);
SELECT public.seed_location_place_v1('NG', 'ED', 'Benin City', 'city', NULL, 6.3350, 5.6037, NULL, 50, ARRAY['Benin']);
SELECT public.seed_location_place_v1('NG', 'EN', 'Enugu', 'city', NULL, 6.5244, 7.5187, NULL, 60, ARRAY['Enugu City']);
SELECT public.seed_location_place_v1('NG', 'KN', 'Kano', 'city', NULL, 12.0022, 8.5920, NULL, 70, ARRAY['Kano City']);
SELECT public.seed_location_place_v1('NG', 'KD', 'Kaduna', 'city', NULL, 10.5105, 7.4165, NULL, 80, ARRAY['Kaduna City']);
SELECT public.seed_location_place_v1('NG', 'OG', 'Abeokuta', 'city', NULL, 7.1475, 3.3619, NULL, 90, ARRAY['Abeokuta Ogun']);
SELECT public.seed_location_place_v1('NG', 'IM', 'Owerri', 'city', NULL, 5.4850, 7.0350, NULL, 100, ARRAY['Owerri Imo']);

-- Lagos areas
SELECT public.seed_location_place_v1('NG', 'LA', 'Lekki', 'local_area', 'Lagos', 6.4698, 3.5852, NULL, 110, ARRAY['Lekki Phase 1', 'Lekki 1']);
SELECT public.seed_location_place_v1('NG', 'LA', 'Victoria Island', 'local_area', 'Lagos', 6.4281, 3.4219, NULL, 120, ARRAY['VI', 'V.I', 'V.I.', 'Victoria Island Lagos']);
SELECT public.seed_location_place_v1('NG', 'LA', 'Ikoyi', 'local_area', 'Lagos', 6.4541, 3.4256, NULL, 130, ARRAY['Ikoyi Lagos']);
SELECT public.seed_location_place_v1('NG', 'LA', 'Ikeja', 'local_area', 'Lagos', 6.6018, 3.3515, NULL, 140, ARRAY['Ikeja Lagos']);
SELECT public.seed_location_place_v1('NG', 'LA', 'Yaba', 'local_area', 'Lagos', 6.5158, 3.3898, NULL, 150, ARRAY['Yaba Lagos']);
SELECT public.seed_location_place_v1('NG', 'LA', 'Surulere', 'local_area', 'Lagos', 6.5000, 3.3500, NULL, 160, ARRAY['Surulere Lagos']);
SELECT public.seed_location_place_v1('NG', 'LA', 'Ajah', 'local_area', 'Lagos', 6.4698, 3.5852, NULL, 170, ARRAY['Ajah Lagos']);
SELECT public.seed_location_place_v1('NG', 'LA', 'Lagos Island', 'local_area', 'Lagos', 6.4549, 3.4246, NULL, 180, ARRAY['Island', 'Lagos Island Lagos']);
SELECT public.seed_location_place_v1('NG', 'LA', 'Somolu', 'local_area', 'Lagos', 6.5392, 3.3840, NULL, 190, ARRAY['Shomolu', 'Somolu Lagos', 'Shomolu Lagos']);

-- Abuja/FCT areas
SELECT public.seed_location_place_v1('NG', 'FC', 'Wuse', 'local_area', 'Abuja', 9.0765, 7.4704, NULL, 200, ARRAY['Wuse Abuja']);
SELECT public.seed_location_place_v1('NG', 'FC', 'Maitama', 'local_area', 'Abuja', 9.0955, 7.4951, NULL, 210, ARRAY['Maitama Abuja']);
SELECT public.seed_location_place_v1('NG', 'FC', 'Garki', 'local_area', 'Abuja', 9.0365, 7.4898, NULL, 220, ARRAY['Garki Abuja']);
SELECT public.seed_location_place_v1('NG', 'FC', 'Asokoro', 'local_area', 'Abuja', 9.0457, 7.5244, NULL, 230, ARRAY['Asokoro Abuja']);
SELECT public.seed_location_place_v1('NG', 'FC', 'Gwarinpa', 'local_area', 'Abuja', 9.1099, 7.4042, NULL, 240, ARRAY['Gwarimpa', 'Gwarinpa Abuja']);
SELECT public.seed_location_place_v1('NG', 'FC', 'Jabi', 'local_area', 'Abuja', 9.0687, 7.4250, NULL, 250, ARRAY['Jabi Abuja']);
SELECT public.seed_location_place_v1('NG', 'FC', 'Lugbe', 'local_area', 'Abuja', 8.9850, 7.3650, NULL, 260, ARRAY['Lugbe Abuja']);

-- United States priority cities
SELECT public.seed_location_place_v1('US', 'TX', 'Dallas', 'city', NULL, 32.7767, -96.7970, 1302868, 10, ARRAY['DFW', 'Dallas TX', 'Dallas-Fort Worth']);
SELECT public.seed_location_place_v1('US', 'TX', 'Austin', 'city', NULL, 30.2672, -97.7431, 974447, 20, ARRAY['Austin TX']);
SELECT public.seed_location_place_v1('US', 'TX', 'Houston', 'city', NULL, 29.7604, -95.3698, 2304580, 30, ARRAY['Houston TX']);
SELECT public.seed_location_place_v1('US', 'GA', 'Atlanta', 'city', NULL, 33.7490, -84.3880, 498715, 40, ARRAY['Atlanta GA', 'ATL']);
SELECT public.seed_location_place_v1('US', 'FL', 'Miami', 'city', NULL, 25.7617, -80.1918, 442241, 50, ARRAY['Miami FL']);
SELECT public.seed_location_place_v1('US', 'NY', 'New York', 'city', NULL, 40.7128, -74.0060, 8335897, 60, ARRAY['NYC', 'New York City']);
SELECT public.seed_location_place_v1('US', 'CA', 'Los Angeles', 'city', NULL, 34.0522, -118.2437, 3822238, 70, ARRAY['LA', 'L.A.', 'Los Angeles CA']);
SELECT public.seed_location_place_v1('US', 'IL', 'Chicago', 'city', NULL, 41.8781, -87.6298, 2665039, 80, ARRAY['Chicago IL']);
SELECT public.seed_location_place_v1('US', 'DC', 'Washington', 'city', NULL, 38.9072, -77.0369, 671803, 90, ARRAY['DC', 'Washington DC', 'Washington, DC']);
SELECT public.seed_location_place_v1('US', 'CA', 'San Francisco', 'city', NULL, 37.7749, -122.4194, 808437, 100, ARRAY['SF', 'San Fran', 'San Francisco CA']);
SELECT public.seed_location_place_v1('US', 'AZ', 'Phoenix', 'city', NULL, 33.4484, -112.0740, 1644409, 110, ARRAY['Phenix', 'Phoenix AZ']);

-- Canada priority cities
SELECT public.seed_location_place_v1('CA', 'ON', 'Toronto', 'city', NULL, 43.6532, -79.3832, 2794356, 10, ARRAY['GTA', 'TO', 'YYZ', 'Greater Toronto Area']);
SELECT public.seed_location_place_v1('CA', 'BC', 'Vancouver', 'city', NULL, 49.2827, -123.1207, 662248, 20, ARRAY['YVR', 'VanCity', 'Vancouver BC']);
SELECT public.seed_location_place_v1('CA', 'QC', 'Montreal', 'city', NULL, 45.5017, -73.5673, 1762949, 30, ARRAY['Montréal', 'MTL', 'Montreal QC']);
SELECT public.seed_location_place_v1('CA', 'AB', 'Calgary', 'city', NULL, 51.0447, -114.0719, 1306784, 40, ARRAY['Calgary AB']);
SELECT public.seed_location_place_v1('CA', 'AB', 'Edmonton', 'city', NULL, 53.5461, -113.4938, 1010899, 50, ARRAY['Edmonton AB']);
SELECT public.seed_location_place_v1('CA', 'ON', 'Ottawa', 'city', NULL, 45.4215, -75.6972, 1017449, 60, ARRAY['Ottawa ON']);
SELECT public.seed_location_place_v1('CA', 'MB', 'Winnipeg', 'city', NULL, 49.8951, -97.1384, 749607, 70, ARRAY['Winnipeg MB']);
SELECT public.seed_location_place_v1('CA', 'ON', 'Mississauga', 'city', NULL, 43.5890, -79.6441, 717961, 80, ARRAY['Mississauga GTA']);
SELECT public.seed_location_place_v1('CA', 'ON', 'Brampton', 'city', NULL, 43.7315, -79.7624, 656480, 90, ARRAY['Brampton GTA']);
SELECT public.seed_location_place_v1('CA', 'ON', 'Hamilton', 'city', NULL, 43.2557, -79.8711, 569353, 100, ARRAY['Hamilton ON']);

-- UK, Ghana, South Africa, Kenya starter cities
SELECT public.seed_location_place_v1('GB', 'ENG', 'London', 'city', NULL, 51.5072, -0.1276, 8799800, 10, ARRAY['LDN', 'London UK']);
SELECT public.seed_location_place_v1('GB', 'ENG', 'Manchester', 'city', NULL, 53.4808, -2.2426, 552858, 20, ARRAY['Manchester UK']);
SELECT public.seed_location_place_v1('GB', 'ENG', 'Birmingham', 'city', NULL, 52.4862, -1.8904, 1144900, 30, ARRAY['Birmingham UK']);
SELECT public.seed_location_place_v1('GH', 'AA', 'Accra', 'city', NULL, 5.6037, -0.1870, 2282000, 10, ARRAY['Accra Ghana']);
SELECT public.seed_location_place_v1('GH', 'AS', 'Kumasi', 'city', NULL, 6.6666, -1.6163, 3490030, 20, ARRAY['Kumasi Ghana']);
SELECT public.seed_location_place_v1('ZA', 'GT', 'Johannesburg', 'city', NULL, -26.2041, 28.0473, 5635127, 10, ARRAY['Joburg', 'Jozi', 'JHB']);
SELECT public.seed_location_place_v1('ZA', 'WC', 'Cape Town', 'city', NULL, -33.9249, 18.4241, 4618000, 20, ARRAY['Cape Town SA']);
SELECT public.seed_location_place_v1('ZA', 'KZN', 'Durban', 'city', NULL, -29.8587, 31.0218, 3982000, 30, ARRAY['Durbs']);
SELECT public.seed_location_place_v1('KE', 'NAI', 'Nairobi', 'city', NULL, -1.2921, 36.8219, 4397000, 10, ARRAY['NBO', 'Nairobi Kenya']);
SELECT public.seed_location_place_v1('KE', 'MOM', 'Mombasa', 'city', NULL, -4.0435, 39.6682, 1208333, 20, ARRAY['Mombasa Kenya']);
SELECT public.seed_location_place_v1('KE', 'KSM', 'Kisumu', 'city', NULL, -0.0917, 34.7680, 610082, 30, ARRAY['Kisumu Kenya']);

DROP FUNCTION IF EXISTS public.search_locations(TEXT, TEXT, UUID, INTEGER);

CREATE OR REPLACE FUNCTION public.search_locations(
  p_query TEXT DEFAULT '',
  p_country_code TEXT DEFAULT NULL,
  p_region_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 20
)
RETURNS TABLE (
  place_id UUID,
  parent_place_id UUID,
  parent_place_name TEXT,
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
      parent.id AS parent_place_id,
      parent.name AS parent_place_name,
      lp.country_code,
      lc.name AS country_name,
      lr.id AS region_id,
      lr.region_code,
      lr.name AS region_name,
      lp.name AS place_name,
      lp.place_type,
      CASE
        WHEN parent.id IS NOT NULL
          THEN CONCAT_WS(', ', lp.name, parent.name, lr.name, lc.name)
        ELSE CONCAT_WS(', ', lp.name, lr.name, lc.name)
      END AS display_name,
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
    LEFT JOIN public.location_places parent ON parent.id = lp.parent_place_id
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
    parent_place_id,
    parent_place_name,
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
    CASE place_type WHEN 'city' THEN 1 ELSE 2 END,
    population DESC NULLS LAST,
    display_name ASC
  LIMIT (SELECT max_rows FROM input);
$$;

CREATE OR REPLACE FUNCTION public.set_user_canonical_location()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_area public.location_places%ROWTYPE;
  v_city public.location_places%ROWTYPE;
  v_region public.location_regions%ROWTYPE;
  v_country public.location_countries%ROWTYPE;
  v_location RECORD;
BEGIN
  IF NEW.area_place_id IS NOT NULL THEN
    SELECT * INTO v_area
    FROM public.location_places
    WHERE id = NEW.area_place_id AND enabled = true
    LIMIT 1;

    IF FOUND THEN
      NEW.canonical_place_id := v_area.id;
      NEW.country_code := v_area.country_code;
      NEW.region_id := v_area.region_id;
      NEW.city_place_id := COALESCE(v_area.parent_place_id, NEW.city_place_id);
    END IF;
  END IF;

  IF NEW.city_place_id IS NOT NULL THEN
    SELECT * INTO v_city
    FROM public.location_places
    WHERE id = NEW.city_place_id AND enabled = true
    LIMIT 1;

    IF FOUND THEN
      NEW.country_code := v_city.country_code;
      NEW.region_id := v_city.region_id;
      IF NEW.area_place_id IS NULL THEN
        NEW.canonical_place_id := v_city.id;
      END IF;
    END IF;
  END IF;

  IF NEW.region_id IS NOT NULL THEN
    SELECT * INTO v_region
    FROM public.location_regions
    WHERE id = NEW.region_id
    LIMIT 1;
    IF FOUND THEN
      NEW.state_region := v_region.name;
      NEW.country_code := COALESCE(NEW.country_code, v_region.country_code);
    END IF;
  END IF;

  IF NEW.country_code IS NOT NULL THEN
    SELECT * INTO v_country
    FROM public.location_countries
    WHERE code = NEW.country_code
    LIMIT 1;
    IF FOUND THEN
      NEW.country := v_country.code;
    END IF;
  END IF;

  IF v_city.id IS NOT NULL THEN
    NEW.city := v_city.name;
    NEW.metro_area := COALESCE(v_area.name, v_city.name);
    NEW.canonical_city := v_city.name;
    NEW.canonical_state_region := COALESCE(v_region.name, NEW.state_region);
    NEW.canonical_country := COALESCE(v_country.code, NEW.country_code, NEW.country);
    NEW.canonical_metro_area := COALESCE(v_area.name, v_city.name);
    NEW.location_canonical_key := CONCAT_WS(
      ':',
      public.location_alias_key(NEW.canonical_country),
      public.location_alias_key(NEW.canonical_state_region),
      public.location_alias_key(NEW.canonical_city),
      public.location_alias_key(v_area.name)
    );
    NEW.location_display_name := public.location_display_name(
      v_area.name,
      v_city.name,
      COALESCE(v_region.name, NEW.state_region),
      COALESCE(v_country.name, NEW.country)
    );
  ELSE
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
  END IF;

  NEW.location_updated_at := COALESCE(NEW.location_updated_at, now());

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_set_canonical_location ON public.users;
CREATE TRIGGER users_set_canonical_location
BEFORE INSERT OR UPDATE OF
  city,
  state_region,
  country,
  metro_area,
  country_code,
  region_id,
  city_place_id,
  area_place_id
ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.set_user_canonical_location();

CREATE OR REPLACE FUNCTION public.get_discovery_feed(p_limit INTEGER DEFAULT 20)
RETURNS SETOF public.users
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH self_user AS (
    SELECT *
    FROM public.users
    WHERE id = auth.uid()
  ),
  candidates AS (
    SELECT
      u.id,
      CASE
        WHEN su.area_place_id IS NOT NULL
          AND u.area_place_id = su.area_place_id THEN 80
        WHEN su.city_place_id IS NOT NULL
          AND u.city_place_id = su.city_place_id THEN 60
        WHEN su.region_id IS NOT NULL
          AND u.region_id = su.region_id THEN 40
        WHEN su.country_code IS NOT NULL
          AND u.country_code = su.country_code THEN 20
        WHEN su.canonical_metro_area IS NOT NULL
          AND u.canonical_metro_area = su.canonical_metro_area THEN 15
        WHEN su.canonical_city IS NOT NULL
          AND u.canonical_city = su.canonical_city
          AND COALESCE(u.canonical_country, '') = COALESCE(su.canonical_country, '') THEN 12
        WHEN su.canonical_country IS NOT NULL
          AND u.canonical_country = su.canonical_country THEN 8
        ELSE 0
      END AS location_rank
    FROM public.users u
    CROSS JOIN self_user su
    WHERE auth.uid() IS NOT NULL
      AND u.id <> auth.uid()
      AND COALESCE(u.onboarding_complete, false) = true
      AND COALESCE(u.moderation_status, 'pending') = 'approved'
      AND COALESCE(u.account_status, 'active') = 'active'
      AND COALESCE(u.profile_visibility_status, 'visible') = 'visible'
      AND NOT EXISTS (
        SELECT 1
        FROM public.interactions i
        WHERE i.from_user_id = auth.uid()
          AND i.to_user_id = u.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.blocked_users b
        WHERE (b.blocker_user_id = auth.uid() AND b.blocked_user_id = u.id)
           OR (b.blocker_user_id = u.id AND b.blocked_user_id = auth.uid())
      )
      AND (
        CASE
          WHEN lower(COALESCE(su.interested_in::TEXT, '')) = 'everyone' THEN true
          WHEN lower(COALESCE(su.interested_in::TEXT, '')) = 'men' THEN u.gender = 'man'::public.gender_type
          WHEN lower(COALESCE(su.interested_in::TEXT, '')) = 'women' THEN u.gender = 'woman'::public.gender_type
          ELSE lower(COALESCE(u.gender::TEXT, '')) = lower(COALESCE(su.interested_in::TEXT, ''))
        END
      )
      AND (
        CASE
          WHEN lower(COALESCE(u.interested_in::TEXT, '')) = 'everyone' THEN true
          WHEN su.gender = 'man'::public.gender_type THEN u.interested_in = 'men'::public.interested_in_type
          WHEN su.gender = 'woman'::public.gender_type THEN u.interested_in = 'women'::public.interested_in_type
          ELSE lower(COALESCE(u.interested_in::TEXT, '')) = lower(COALESCE(su.gender::TEXT, ''))
        END
      )
  )
  SELECT u.*
  FROM candidates
  JOIN public.users u ON u.id = candidates.id
  ORDER BY
    candidates.location_rank DESC,
    COALESCE(u.is_verified, false) DESC,
    CASE u.verification_status WHEN 'verified'::public.verification_status_type THEN 1 ELSE 0 END DESC,
    u.last_active DESC NULLS LAST,
    u.created_at DESC NULLS LAST
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 100));
$$;

UPDATE public.users u
SET location_updated_at = COALESCE(u.location_updated_at, now())
WHERE u.location_updated_at IS NULL
  AND (
    u.city_place_id IS NOT NULL
    OR u.area_place_id IS NOT NULL
    OR u.canonical_place_id IS NOT NULL
    OR COALESCE(NULLIF(btrim(u.city), ''), '') <> ''
  );

DROP FUNCTION IF EXISTS public.seed_location_place_v1(
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

GRANT EXECUTE ON FUNCTION public.search_locations(TEXT, TEXT, UUID, INTEGER) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_discovery_feed(INTEGER) TO authenticated;
