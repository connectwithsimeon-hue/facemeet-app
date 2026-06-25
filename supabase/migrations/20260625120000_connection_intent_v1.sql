-- FaceMeet Connection Intent v1.
-- Adds a lightweight "what are you here for?" layer without changing existing
-- dating/safety/location discovery constraints.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS connection_intent TEXT;

UPDATE public.users
SET connection_intent = 'dating'
WHERE connection_intent IS NULL;

ALTER TABLE public.users
  ALTER COLUMN connection_intent SET DEFAULT 'dating';

DO $$
BEGIN
  ALTER TABLE public.users
    ADD CONSTRAINT users_connection_intent_check
    CHECK (
      connection_intent IS NULL
      OR connection_intent IN (
        'dating',
        'friendship',
        'professional',
        'events',
        'open_to_all'
      )
    );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_users_connection_intent
  ON public.users(connection_intent);

DROP FUNCTION IF EXISTS public.get_discovery_feed(INTEGER);

CREATE OR REPLACE FUNCTION public.get_discovery_feed(
  p_limit INTEGER DEFAULT 20,
  p_connection_intent_filter TEXT DEFAULT 'all'
)
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
  normalized_filter AS (
    SELECT lower(COALESCE(NULLIF(btrim(p_connection_intent_filter), ''), 'all')) AS value
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
    CROSS JOIN normalized_filter nf
    WHERE auth.uid() IS NOT NULL
      AND u.id <> auth.uid()
      AND COALESCE(u.onboarding_complete, false) = true
      AND COALESCE(u.moderation_status, 'pending') = 'approved'
      AND COALESCE(u.account_status, 'active') = 'active'
      AND COALESCE(u.profile_visibility_status, 'visible') = 'visible'
      AND (
        CASE nf.value
          WHEN 'dating' THEN COALESCE(u.connection_intent, 'dating') IN ('dating', 'open_to_all')
          WHEN 'friendship' THEN COALESCE(u.connection_intent, 'dating') IN ('friendship', 'open_to_all')
          WHEN 'professional' THEN COALESCE(u.connection_intent, 'dating') IN ('professional', 'open_to_all')
          WHEN 'events' THEN COALESCE(u.connection_intent, 'dating') IN ('events', 'open_to_all')
          ELSE TRUE
        END
      )
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

GRANT EXECUTE ON FUNCTION public.get_discovery_feed(INTEGER, TEXT) TO authenticated;
