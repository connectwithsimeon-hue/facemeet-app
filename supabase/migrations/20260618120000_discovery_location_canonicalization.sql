-- Canonicalize user-entered locations and expose server-ranked discovery.
-- This keeps the app UI unchanged while preventing spelling variants like
-- "ABJ", "FCT-Abuja", and "Abuja FCT" from splitting one market.

CREATE TABLE IF NOT EXISTS public.location_aliases (
  alias_key TEXT PRIMARY KEY,
  canonical_city TEXT NOT NULL,
  canonical_state_region TEXT,
  canonical_country TEXT NOT NULL,
  canonical_metro_area TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_location_aliases_canonical
  ON public.location_aliases(canonical_country, canonical_state_region, canonical_city);

CREATE OR REPLACE FUNCTION public.location_alias_key(p_value TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(
    regexp_replace(
      lower(btrim(COALESCE(p_value, ''))),
      '[^a-z0-9]+',
      '',
      'g'
    ),
    ''
  );
$$;

CREATE OR REPLACE FUNCTION public.canonical_country_code(p_country TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE public.location_alias_key(p_country)
    WHEN 'us' THEN 'US'
    WHEN 'usa' THEN 'US'
    WHEN 'unitedstates' THEN 'US'
    WHEN 'unitedstatesofamerica' THEN 'US'
    WHEN 'ca' THEN 'CA'
    WHEN 'canada' THEN 'CA'
    WHEN 'ng' THEN 'NG'
    WHEN 'nigeria' THEN 'NG'
    ELSE NULLIF(upper(btrim(COALESCE(p_country, ''))), '')
  END;
$$;

INSERT INTO public.location_aliases
  (alias_key, canonical_city, canonical_state_region, canonical_country, canonical_metro_area)
VALUES
  -- Nigeria: Abuja / Federal Capital Territory
  ('abuja', 'Abuja', 'FCT', 'NG', 'Abuja'),
  ('abujaabuja', 'Abuja', 'FCT', 'NG', 'Abuja'),
  ('abj', 'Abuja', 'FCT', 'NG', 'Abuja'),
  ('fct', 'Abuja', 'FCT', 'NG', 'Abuja'),
  ('fctabuja', 'Abuja', 'FCT', 'NG', 'Abuja'),
  ('abujafct', 'Abuja', 'FCT', 'NG', 'Abuja'),
  ('federalcapitalterritory', 'Abuja', 'FCT', 'NG', 'Abuja'),
  ('federalcapitalterritoryabuja', 'Abuja', 'FCT', 'NG', 'Abuja'),
  ('abujafederalcapitalterritory', 'Abuja', 'FCT', 'NG', 'Abuja'),
  -- Nigeria: Lagos
  ('lagos', 'Lagos', 'Lagos', 'NG', 'Lagos'),
  ('lag', 'Lagos', 'Lagos', 'NG', 'Lagos'),
  ('lagosstate', 'Lagos', 'Lagos', 'NG', 'Lagos'),
  -- Canada launch markets
  ('toronto', 'Toronto', 'Ontario', 'CA', 'Toronto'),
  ('torontoontario', 'Toronto', 'Ontario', 'CA', 'Toronto'),
  ('torontoon', 'Toronto', 'Ontario', 'CA', 'Toronto'),
  ('gta', 'Toronto', 'Ontario', 'CA', 'Toronto'),
  ('greatertorontoarea', 'Toronto', 'Ontario', 'CA', 'Toronto'),
  ('vancouver', 'Vancouver', 'British Columbia', 'CA', 'Vancouver'),
  ('vancouverbc', 'Vancouver', 'British Columbia', 'CA', 'Vancouver'),
  ('montreal', 'Montreal', 'Quebec', 'CA', 'Montreal'),
  ('montréal', 'Montreal', 'Quebec', 'CA', 'Montreal'),
  ('montral', 'Montreal', 'Quebec', 'CA', 'Montreal'),
  ('montrealqc', 'Montreal', 'Quebec', 'CA', 'Montreal'),
  -- Existing US market examples
  ('dallas', 'Dallas', 'Texas', 'US', 'Dallas'),
  ('dallastx', 'Dallas', 'Texas', 'US', 'Dallas'),
  ('dfw', 'Dallas', 'Texas', 'US', 'Dallas')
ON CONFLICT (alias_key) DO UPDATE
SET canonical_city = EXCLUDED.canonical_city,
    canonical_state_region = EXCLUDED.canonical_state_region,
    canonical_country = EXCLUDED.canonical_country,
    canonical_metro_area = EXCLUDED.canonical_metro_area;

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS canonical_city TEXT,
  ADD COLUMN IF NOT EXISTS canonical_state_region TEXT,
  ADD COLUMN IF NOT EXISTS canonical_country TEXT,
  ADD COLUMN IF NOT EXISTS canonical_metro_area TEXT,
  ADD COLUMN IF NOT EXISTS location_canonical_key TEXT;

CREATE INDEX IF NOT EXISTS idx_users_canonical_location
  ON public.users(canonical_country, canonical_state_region, canonical_city);

CREATE INDEX IF NOT EXISTS idx_users_discovery_rank
  ON public.users(
    onboarding_complete,
    moderation_status,
    account_status,
    profile_visibility_status,
    canonical_country,
    canonical_state_region,
    canonical_city,
    last_active
  );

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
  location_canonical_key TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_city TEXT := NULLIF(btrim(COALESCE(p_city, '')), '');
  v_state TEXT := NULLIF(btrim(COALESCE(p_state_region, '')), '');
  v_country TEXT := public.canonical_country_code(p_country);
  v_metro TEXT := NULLIF(btrim(COALESCE(p_metro_area, '')), '');
  v_alias public.location_aliases%ROWTYPE;
BEGIN
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
  ELSE
    city := v_city;
    state_region := v_state;
    country := v_country;
    metro_area := v_metro;
    canonical_city := v_city;
    canonical_state_region := v_state;
    canonical_country := v_country;
    canonical_metro_area := COALESCE(v_metro, v_city);
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

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_set_canonical_location ON public.users;
CREATE TRIGGER users_set_canonical_location
BEFORE INSERT OR UPDATE OF city, state_region, country, metro_area
ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.set_user_canonical_location();

UPDATE public.users u
SET city = normalized.city,
    state_region = normalized.state_region,
    country = normalized.country,
    metro_area = normalized.metro_area,
    canonical_city = normalized.canonical_city,
    canonical_state_region = normalized.canonical_state_region,
    canonical_country = normalized.canonical_country,
    canonical_metro_area = normalized.canonical_metro_area,
    location_canonical_key = normalized.location_canonical_key
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
    normalized.location_canonical_key
  FROM public.users existing
  CROSS JOIN LATERAL public.canonicalize_location_parts(
    existing.city,
    existing.state_region,
    existing.country,
    existing.metro_area
  ) AS normalized
) AS normalized
WHERE u.id = normalized.id;

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
        WHEN su.canonical_metro_area IS NOT NULL
          AND u.canonical_metro_area = su.canonical_metro_area THEN 50
        WHEN su.canonical_city IS NOT NULL
          AND u.canonical_city = su.canonical_city
          AND COALESCE(u.canonical_country, '') = COALESCE(su.canonical_country, '') THEN 45
        WHEN su.canonical_state_region IS NOT NULL
          AND u.canonical_state_region = su.canonical_state_region
          AND COALESCE(u.canonical_country, '') = COALESCE(su.canonical_country, '') THEN 30
        WHEN su.canonical_country IS NOT NULL
          AND u.canonical_country = su.canonical_country THEN 15
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

GRANT EXECUTE ON FUNCTION public.get_discovery_feed(INTEGER) TO authenticated;
