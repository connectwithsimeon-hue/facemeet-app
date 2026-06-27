-- Public shareable profiles v1 backend foundation.
-- Adds opt-in public profile slugs, safe public RPCs, and lightweight tracking.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS public_profile_enabled BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS public_profile_slug TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS public_profile_created_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS public_profile_updated_at TIMESTAMPTZ;

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_public_profile_slug_format_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_public_profile_slug_format_check
  CHECK (
    public_profile_slug IS NULL
    OR public_profile_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
  );

CREATE INDEX IF NOT EXISTS idx_users_public_profile_enabled_slug
  ON public.users(public_profile_enabled, public_profile_slug)
  WHERE public_profile_slug IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_users_public_profile_safety
  ON public.users(public_profile_enabled, account_status, profile_visibility_status, moderation_status, onboarding_complete);

CREATE OR REPLACE FUNCTION public.public_profile_slug_base(p_source TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_slug TEXT;
BEGIN
  v_slug := lower(COALESCE(p_source, ''));
  v_slug := regexp_replace(v_slug, '[^a-z0-9]+', '-', 'g');
  v_slug := regexp_replace(v_slug, '(^-+|-+$)', '', 'g');
  v_slug := NULLIF(v_slug, '');

  RETURN COALESCE(v_slug, 'facemeet');
END;
$$;

CREATE OR REPLACE FUNCTION public.generate_public_profile_slug(
  p_user_id UUID,
  p_username TEXT,
  p_first_name TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_base TEXT := public.public_profile_slug_base(COALESCE(NULLIF(BTRIM(p_username), ''), NULLIF(BTRIM(p_first_name), '')));
  v_candidate TEXT;
  v_suffix TEXT;
  v_attempt INTEGER := 0;
BEGIN
  LOOP
    IF v_attempt = 0 THEN
      v_candidate := v_base;
    ELSE
      v_suffix := substring(replace(gen_random_uuid()::TEXT, '-', '') from 1 for 4);
      v_candidate := v_base || '-' || v_suffix;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.public_profile_slug = v_candidate
        AND u.id <> p_user_id
    ) THEN
      RETURN v_candidate;
    END IF;

    v_attempt := v_attempt + 1;
    IF v_attempt > 30 THEN
      RETURN 'facemeet-' || substring(replace(gen_random_uuid()::TEXT, '-', '') from 1 for 8);
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.is_public_profile_safe(p_user public.users)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT
    COALESCE(p_user.public_profile_enabled, false) = true
    AND COALESCE(p_user.onboarding_complete, false) = true
    AND COALESCE(p_user.account_status, 'active') = 'active'
    AND COALESCE(p_user.profile_visibility_status, 'visible') = 'visible'
    AND COALESCE(p_user.moderation_status, 'pending') = 'approved'
    AND COALESCE(NULLIF(BTRIM(p_user.public_profile_slug), ''), '') <> '';
$$;

CREATE OR REPLACE FUNCTION public.public_connection_intent_label(p_connection_intent TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE COALESCE(NULLIF(lower(BTRIM(p_connection_intent)), ''), 'dating')
    WHEN 'friendship' THEN 'Friendship'
    WHEN 'professional' THEN 'Professional Connections'
    WHEN 'events' THEN 'Events'
    WHEN 'open_to_all' THEN 'Open to All'
    ELSE 'Dating'
  END;
$$;

CREATE OR REPLACE FUNCTION public.enable_my_public_profile()
RETURNS TABLE (
  slug TEXT,
  public_path TEXT,
  public_profile_enabled BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user public.users;
  v_slug TEXT;
BEGIN
  SELECT *
  INTO v_user
  FROM public.users u
  WHERE u.id = auth.uid()
  LIMIT 1;

  IF v_user.id IS NULL THEN
    RAISE EXCEPTION 'profile not found';
  END IF;

  IF COALESCE(v_user.onboarding_complete, false) IS DISTINCT FROM true
     OR COALESCE(v_user.account_status, 'active') <> 'active'
     OR COALESCE(v_user.profile_visibility_status, 'visible') <> 'visible'
     OR COALESCE(v_user.moderation_status, 'pending') <> 'approved' THEN
    RAISE EXCEPTION 'profile is not eligible for public sharing';
  END IF;

  v_slug := COALESCE(
    NULLIF(BTRIM(v_user.public_profile_slug), ''),
    public.generate_public_profile_slug(v_user.id, v_user.username, v_user.first_name)
  );

  UPDATE public.users
  SET public_profile_enabled = true,
      public_profile_slug = v_slug,
      public_profile_created_at = COALESCE(public_profile_created_at, now()),
      public_profile_updated_at = now()
  WHERE id = v_user.id
  RETURNING public.users.public_profile_slug INTO v_slug;

  slug := v_slug;
  public_path := '/p/' || v_slug;
  public_profile_enabled := true;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.disable_my_public_profile()
RETURNS TABLE (
  success BOOLEAN,
  public_profile_enabled BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users
  SET public_profile_enabled = false,
      public_profile_updated_at = now()
  WHERE id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile not found';
  END IF;

  success := true;
  public_profile_enabled := false;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_public_profile_by_slug(profile_slug TEXT)
RETURNS TABLE (
  public_profile_slug TEXT,
  first_name TEXT,
  display_name TEXT,
  age INTEGER,
  bio TEXT,
  thumbnail_url TEXT,
  profile_video_url TEXT,
  connection_intent TEXT,
  connection_intent_label TEXT,
  location_display_name TEXT,
  city TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    u.public_profile_slug,
    u.first_name,
    COALESCE(NULLIF(BTRIM(u.first_name), ''), NULLIF(BTRIM(u.username), ''), 'FaceMeet member') AS display_name,
    u.age,
    u.bio,
    u.thumbnail_url,
    u.profile_video_url,
    COALESCE(NULLIF(lower(BTRIM(u.connection_intent)), ''), 'dating') AS connection_intent,
    public.public_connection_intent_label(u.connection_intent) AS connection_intent_label,
    COALESCE(NULLIF(BTRIM(u.location_display_name), ''), NULLIF(BTRIM(u.metro_area), ''), NULLIF(BTRIM(u.city), '')) AS location_display_name,
    u.city
  FROM public.users u
  WHERE u.public_profile_slug = public.public_profile_slug_base(profile_slug)
    AND public.is_public_profile_safe(u)
  LIMIT 1;
$$;

CREATE TABLE IF NOT EXISTS public.public_profile_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  public_profile_slug TEXT NOT NULL,
  profile_owner_user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  referrer TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT public_profile_events_event_type_check CHECK (
    event_type IN (
      'profile_view',
      'android_cta_click',
      'open_app_click',
      'ios_waitlist_click',
      'copy_link_click'
    )
  )
);

CREATE INDEX IF NOT EXISTS idx_public_profile_events_slug_created
  ON public.public_profile_events(public_profile_slug, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_public_profile_events_owner_created
  ON public.public_profile_events(profile_owner_user_id, created_at DESC)
  WHERE profile_owner_user_id IS NOT NULL;

ALTER TABLE public.public_profile_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.public_profile_events FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.record_public_profile_event(
  profile_slug TEXT,
  event_type TEXT,
  referrer TEXT DEFAULT NULL
)
RETURNS TABLE (
  success BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_slug TEXT := public.public_profile_slug_base(profile_slug);
  v_event_type TEXT := lower(BTRIM(COALESCE(event_type, '')));
  v_owner_user_id UUID;
BEGIN
  IF v_event_type NOT IN (
    'profile_view',
    'android_cta_click',
    'open_app_click',
    'ios_waitlist_click',
    'copy_link_click'
  ) THEN
    RAISE EXCEPTION 'invalid public profile event type';
  END IF;

  SELECT u.id
  INTO v_owner_user_id
  FROM public.users u
  WHERE u.public_profile_slug = v_slug
    AND public.is_public_profile_safe(u)
  LIMIT 1;

  IF v_owner_user_id IS NULL THEN
    success := false;
    RETURN NEXT;
    RETURN;
  END IF;

  INSERT INTO public.public_profile_events (
    public_profile_slug,
    profile_owner_user_id,
    event_type,
    referrer
  )
  VALUES (
    v_slug,
    v_owner_user_id,
    v_event_type,
    NULLIF(left(BTRIM(COALESCE(referrer, '')), 500), '')
  );

  success := true;
  RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.enable_my_public_profile() TO authenticated;
GRANT EXECUTE ON FUNCTION public.disable_my_public_profile() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_profile_by_slug(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_public_profile_event(TEXT, TEXT, TEXT) TO anon, authenticated;
