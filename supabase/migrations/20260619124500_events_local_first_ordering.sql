ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS country_code TEXT REFERENCES public.location_countries(code) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS region_id UUID REFERENCES public.location_regions(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS city_place_id UUID REFERENCES public.location_places(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS area_place_id UUID REFERENCES public.location_places(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_events_canonical_location
  ON public.events(country_code, region_id, city_place_id, area_place_id);

WITH rollout_locations(slug, country_code, region_code, city_name) AS (
  VALUES
    ('facemeet-dallas-social-2026-07-16', 'US', 'TX', 'Dallas'),
    ('facemeet-austin-social-2026-08-05', 'US', 'TX', 'Austin'),
    ('facemeet-houston-social-2026-08-20', 'US', 'TX', 'Houston'),
    ('facemeet-atlanta-social-2026-09-05', 'US', 'GA', 'Atlanta'),
    ('facemeet-miami-social-2026-09-20', 'US', 'FL', 'Miami'),
    ('facemeet-new-york-social-2026-10-05', 'US', 'NY', 'New York'),
    ('facemeet-los-angeles-social-2026-10-20', 'US', 'CA', 'Los Angeles'),
    ('facemeet-chicago-social-2026-11-05', 'US', 'IL', 'Chicago'),
    ('facemeet-washington-dc-social-2026-11-20', 'US', 'DC', 'Washington'),
    ('facemeet-san-francisco-social-2026-12-05', 'US', 'CA', 'San Francisco'),
    ('facemeet-lagos-social-2026-12-20', 'NG', 'LA', 'Lagos')
),
resolved_locations AS (
  SELECT
    rl.slug,
    lp.country_code,
    lp.region_id,
    lp.id AS city_place_id
  FROM rollout_locations rl
  JOIN public.location_regions lr
    ON lr.country_code = rl.country_code
   AND lr.region_code = rl.region_code
  JOIN public.location_places lp
    ON lp.country_code = rl.country_code
   AND lp.region_id = lr.id
   AND lp.place_type = 'city'
   AND lp.normalized_name = public.location_alias_key(rl.city_name)
)
UPDATE public.events AS e
SET
  country_code = rl.country_code,
  region_id = rl.region_id,
  city_place_id = rl.city_place_id,
  area_place_id = NULL,
  updated_at = now()
FROM resolved_locations rl
WHERE e.slug = rl.slug;

DROP FUNCTION IF EXISTS public.get_my_accessible_events();

CREATE OR REPLACE FUNCTION public.get_my_accessible_events()
RETURNS TABLE (
  id UUID,
  title TEXT,
  slug TEXT,
  city_id UUID,
  city_name TEXT,
  venue_name TEXT,
  venue_address TEXT,
  event_type TEXT,
  status TEXT,
  starts_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  capacity INTEGER,
  age_min INTEGER,
  age_max INTEGER,
  price_cents INTEGER,
  currency TEXT,
  invite_requirement TEXT,
  visibility TEXT,
  featured BOOLEAN,
  hero_image_url TEXT,
  short_description TEXT,
  full_description TEXT,
  created_by_admin_id UUID,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  guest_list_status TEXT,
  video_required BOOLEAN,
  verification_required BOOLEAN,
  access_note TEXT,
  access_mode TEXT,
  pairing_preferences_status TEXT,
  country_code TEXT,
  region_id UUID,
  city_place_id UUID,
  area_place_id UUID,
  location_relevance_rank INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH viewer_location AS (
    SELECT
      u.country_code,
      u.region_id,
      u.city_place_id,
      u.area_place_id
    FROM public.users AS u
    WHERE u.id = auth.uid()
  ),
  candidates AS (
    SELECT e.*
    FROM public.events AS e
    WHERE e.status = 'published'
      AND e.visibility <> 'hidden'

    UNION

    SELECT e.*
    FROM public.events AS e
    JOIN public.event_rsvps AS er
      ON er.event_id = e.id
    WHERE auth.uid() IS NOT NULL
      AND er.user_id = auth.uid()
      AND er.status = 'approved'
  ),
  ranked AS (
    SELECT
      c.*,
      CASE
        WHEN vl.area_place_id IS NOT NULL
          AND c.area_place_id IS NOT NULL
          AND c.area_place_id = vl.area_place_id THEN 1
        WHEN vl.city_place_id IS NOT NULL
          AND c.city_place_id IS NOT NULL
          AND c.city_place_id = vl.city_place_id THEN 2
        WHEN vl.region_id IS NOT NULL
          AND c.region_id IS NOT NULL
          AND c.region_id = vl.region_id THEN 3
        WHEN vl.country_code IS NOT NULL
          AND c.country_code IS NOT NULL
          AND c.country_code = vl.country_code THEN 4
        ELSE 5
      END AS location_relevance_rank
    FROM candidates AS c
    LEFT JOIN viewer_location AS vl ON TRUE
  )
  SELECT
    ranked.id,
    ranked.title,
    ranked.slug,
    ranked.city_id,
    ranked.city_name,
    ranked.venue_name,
    ranked.venue_address,
    ranked.event_type,
    ranked.status,
    ranked.starts_at,
    ranked.ends_at,
    ranked.capacity,
    ranked.age_min,
    ranked.age_max,
    ranked.price_cents,
    ranked.currency,
    ranked.invite_requirement,
    ranked.visibility,
    ranked.featured,
    ranked.hero_image_url,
    ranked.short_description,
    ranked.full_description,
    ranked.created_by_admin_id,
    ranked.created_at,
    ranked.updated_at,
    ranked.guest_list_status,
    ranked.video_required,
    ranked.verification_required,
    ranked.access_note,
    ranked.access_mode,
    ranked.pairing_preferences_status,
    ranked.country_code,
    ranked.region_id,
    ranked.city_place_id,
    ranked.area_place_id,
    ranked.location_relevance_rank
  FROM ranked
  ORDER BY
    ranked.location_relevance_rank ASC,
    ranked.featured DESC,
    ranked.starts_at ASC;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_accessible_events() TO anon, authenticated;
