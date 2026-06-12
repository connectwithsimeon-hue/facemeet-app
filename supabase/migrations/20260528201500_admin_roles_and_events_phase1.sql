-- Phase 1 admin hardening + Events foundation
-- Introduces:
--   * admin_users
--   * admin_audit_logs
--   * events
--   * event_rsvps
--   * admin role helper functions
--   * admin-safe RLS for the current static dashboard tables
--   * read/write helpers for app-side events access

CREATE TABLE IF NOT EXISTS public.admin_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('super_admin', 'moderator', 'creator_ops', 'events_ops', 'support_staff')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_users_user_id
  ON public.admin_users(user_id);

CREATE INDEX IF NOT EXISTS idx_admin_users_role_status
  ON public.admin_users(role, status);

CREATE TABLE IF NOT EXISTS public.admin_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id UUID NOT NULL REFERENCES public.admin_users(id) ON DELETE CASCADE,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_admin_user_created
  ON public.admin_audit_logs(admin_user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.current_admin_user_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT au.id
  FROM public.admin_users au
  WHERE au.user_id = auth.uid()
    AND au.status = 'active'
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.has_admin_role(required_roles TEXT[] DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.admin_users au
    WHERE au.user_id = auth.uid()
      AND au.status = 'active'
      AND (
        required_roles IS NULL
        OR cardinality(required_roles) = 0
        OR au.role = ANY(required_roles)
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.log_admin_action(
  p_action TEXT,
  p_target_type TEXT,
  p_target_id TEXT DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_log_id UUID;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  INSERT INTO public.admin_audit_logs (
    admin_user_id,
    action,
    target_type,
    target_id,
    metadata
  )
  VALUES (
    v_admin_user_id,
    p_action,
    p_target_type,
    p_target_id,
    COALESCE(p_metadata, '{}'::JSONB)
  )
  RETURNING id INTO v_log_id;

  RETURN v_log_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.current_admin_user_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_admin_role(TEXT[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_admin_action(TEXT, TEXT, TEXT, JSONB) TO authenticated;

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "approved_admins_read_admin_users" ON public.admin_users;
CREATE POLICY "approved_admins_read_admin_users"
ON public.admin_users
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "super_admins_insert_admin_users" ON public.admin_users;
CREATE POLICY "super_admins_insert_admin_users"
ON public.admin_users
FOR INSERT
TO authenticated
WITH CHECK (public.has_admin_role(ARRAY['super_admin']));

DROP POLICY IF EXISTS "super_admins_update_admin_users" ON public.admin_users;
CREATE POLICY "super_admins_update_admin_users"
ON public.admin_users
FOR UPDATE
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin']));

DROP POLICY IF EXISTS "approved_admins_read_audit_logs" ON public.admin_audit_logs;
CREATE POLICY "approved_admins_read_audit_logs"
ON public.admin_audit_logs
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

CREATE TABLE IF NOT EXISTS public.events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  city_id UUID REFERENCES public.cities(id) ON DELETE SET NULL,
  city_name TEXT,
  venue_name TEXT,
  venue_address TEXT,
  event_type TEXT NOT NULL DEFAULT 'meetup',
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'cancelled', 'archived')),
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  capacity INTEGER,
  age_min INTEGER,
  age_max INTEGER,
  price_cents INTEGER NOT NULL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'USD',
  invite_requirement TEXT NOT NULL DEFAULT 'open' CHECK (invite_requirement IN ('open', 'approval_required', 'invite_only')),
  visibility TEXT NOT NULL DEFAULT 'public' CHECK (visibility IN ('public', 'featured', 'invite_only', 'hidden')),
  featured BOOLEAN NOT NULL DEFAULT false,
  hero_image_url TEXT,
  short_description TEXT,
  full_description TEXT,
  created_by_admin_id UUID REFERENCES public.admin_users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT events_time_check CHECK (ends_at > starts_at),
  CONSTRAINT events_capacity_check CHECK (capacity IS NULL OR capacity >= 0),
  CONSTRAINT events_price_check CHECK (price_cents >= 0),
  CONSTRAINT events_age_range_check CHECK (
    age_min IS NULL OR age_max IS NULL OR age_min <= age_max
  )
);

CREATE INDEX IF NOT EXISTS idx_events_status_starts_at
  ON public.events(status, starts_at);

CREATE INDEX IF NOT EXISTS idx_events_city_name_starts_at
  ON public.events(city_name, starts_at);

CREATE INDEX IF NOT EXISTS idx_events_featured_starts_at
  ON public.events(featured, starts_at)
  WHERE featured = true;

CREATE TABLE IF NOT EXISTS public.event_rsvps (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'requested' CHECK (status IN ('requested', 'waitlisted', 'approved', 'rejected', 'cancelled')),
  requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  reviewed_by_admin_id UUID REFERENCES public.admin_users(id) ON DELETE SET NULL,
  reviewed_at TIMESTAMPTZ,
  admin_note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(event_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_event_rsvps_event_status
  ON public.event_rsvps(event_id, status);

CREATE INDEX IF NOT EXISTS idx_event_rsvps_user_status
  ON public.event_rsvps(user_id, status);

ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_rsvps ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "public_read_published_events" ON public.events;
CREATE POLICY "public_read_published_events"
ON public.events
FOR SELECT
TO anon, authenticated
USING (
  status = 'published'
  AND visibility <> 'hidden'
);

DROP POLICY IF EXISTS "admins_read_all_events" ON public.events;
CREATE POLICY "admins_read_all_events"
ON public.events
FOR SELECT
TO authenticated
USING (
  public.has_admin_role(ARRAY['super_admin', 'events_ops', 'moderator', 'support_staff'])
);

DROP POLICY IF EXISTS "events_ops_manage_events" ON public.events;
CREATE POLICY "events_ops_manage_events"
ON public.events
FOR ALL
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'events_ops']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'events_ops']));

DROP POLICY IF EXISTS "users_read_own_event_rsvps" ON public.event_rsvps;
CREATE POLICY "users_read_own_event_rsvps"
ON public.event_rsvps
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "users_request_own_event_rsvps" ON public.event_rsvps;
CREATE POLICY "users_request_own_event_rsvps"
ON public.event_rsvps
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = auth.uid()
  AND status = 'requested'
  AND EXISTS (
    SELECT 1
    FROM public.events e
    WHERE e.id = event_rsvps.event_id
      AND e.status = 'published'
      AND e.visibility <> 'hidden'
  )
);

DROP POLICY IF EXISTS "admins_read_event_rsvps" ON public.event_rsvps;
CREATE POLICY "admins_read_event_rsvps"
ON public.event_rsvps
FOR SELECT
TO authenticated
USING (
  public.has_admin_role(ARRAY['super_admin', 'events_ops', 'moderator', 'support_staff'])
);

DROP POLICY IF EXISTS "events_ops_manage_event_rsvps" ON public.event_rsvps;
CREATE POLICY "events_ops_manage_event_rsvps"
ON public.event_rsvps
FOR ALL
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'events_ops']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'events_ops']));

CREATE OR REPLACE FUNCTION public.get_published_events()
RETURNS SETOF public.events
LANGUAGE sql
STABLE
AS $$
  SELECT *
  FROM public.events
  WHERE status = 'published'
    AND visibility <> 'hidden'
  ORDER BY starts_at ASC;
$$;

CREATE OR REPLACE FUNCTION public.get_featured_events()
RETURNS SETOF public.events
LANGUAGE sql
STABLE
AS $$
  SELECT *
  FROM public.events
  WHERE status = 'published'
    AND visibility <> 'hidden'
    AND featured = true
  ORDER BY starts_at ASC;
$$;

CREATE OR REPLACE FUNCTION public.get_events_by_city(p_city TEXT)
RETURNS SETOF public.events
LANGUAGE sql
STABLE
AS $$
  SELECT *
  FROM public.events
  WHERE status = 'published'
    AND visibility <> 'hidden'
    AND (
      lower(COALESCE(city_name, '')) = lower(COALESCE(p_city, ''))
      OR city_id IN (
        SELECT id
        FROM public.cities
        WHERE lower(city_name) = lower(COALESCE(p_city, ''))
           OR lower(slug) = lower(COALESCE(p_city, ''))
      )
    )
  ORDER BY starts_at ASC;
$$;

CREATE OR REPLACE FUNCTION public.request_event_invite(p_event_id UUID, p_user_id UUID)
RETURNS public.event_rsvps
LANGUAGE plpgsql
AS $$
DECLARE
  v_row public.event_rsvps;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'user mismatch';
  END IF;

  INSERT INTO public.event_rsvps (event_id, user_id, status, requested_at)
  VALUES (p_event_id, p_user_id, 'requested', now())
  ON CONFLICT (event_id, user_id) DO UPDATE
    SET updated_at = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_event_status(p_user_id UUID, p_event_id UUID)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
  SELECT er.status
  FROM public.event_rsvps er
  WHERE er.user_id = p_user_id
    AND er.event_id = p_event_id
    AND er.user_id = auth.uid()
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.get_published_events() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_featured_events() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_events_by_city(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_event_invite(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_event_status(UUID, UUID) TO authenticated;

ALTER TABLE IF EXISTS public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.interactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.spark_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.user_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.blocked_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.moderation_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.cities ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.creators ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.creator_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.creator_referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.creator_communications ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.creator_payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.waitlist_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.user_referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.city_status_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admins_read_all_users" ON public.users;
CREATE POLICY "admins_read_all_users"
ON public.users
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "moderators_update_users" ON public.users;
CREATE POLICY "moderators_update_users"
ON public.users
FOR UPDATE
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'moderator']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'moderator']));

DROP POLICY IF EXISTS "admins_read_interactions" ON public.interactions;
CREATE POLICY "admins_read_interactions"
ON public.interactions
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "admins_read_matches" ON public.matches;
CREATE POLICY "admins_read_matches"
ON public.matches
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "admins_read_spark_sessions" ON public.spark_sessions;
CREATE POLICY "admins_read_spark_sessions"
ON public.spark_sessions
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "admins_read_messages" ON public.messages;
CREATE POLICY "admins_read_messages"
ON public.messages
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "admins_read_payments" ON public.payments;
CREATE POLICY "admins_read_payments"
ON public.payments
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "admins_read_user_reports" ON public.user_reports;
CREATE POLICY "admins_read_user_reports"
ON public.user_reports
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "moderators_update_user_reports" ON public.user_reports;
CREATE POLICY "moderators_update_user_reports"
ON public.user_reports
FOR UPDATE
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'moderator']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'moderator']));

DROP POLICY IF EXISTS "admins_read_blocked_users" ON public.blocked_users;
CREATE POLICY "admins_read_blocked_users"
ON public.blocked_users
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "admins_read_moderation_events" ON public.moderation_events;
CREATE POLICY "admins_read_moderation_events"
ON public.moderation_events
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "moderators_update_moderation_events" ON public.moderation_events;
CREATE POLICY "moderators_update_moderation_events"
ON public.moderation_events
FOR UPDATE
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'moderator']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'moderator']));

DROP POLICY IF EXISTS "admins_read_cities" ON public.cities;
CREATE POLICY "admins_read_cities"
ON public.cities
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "creator_ops_manage_cities" ON public.cities;
CREATE POLICY "creator_ops_manage_cities"
ON public.cities
FOR ALL
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'creator_ops']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'creator_ops']));

DROP POLICY IF EXISTS "admins_read_creators" ON public.creators;
CREATE POLICY "admins_read_creators"
ON public.creators
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "creator_ops_manage_creators" ON public.creators;
CREATE POLICY "creator_ops_manage_creators"
ON public.creators
FOR ALL
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'creator_ops']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'creator_ops']));

DROP POLICY IF EXISTS "admins_read_creator_applications" ON public.creator_applications;
CREATE POLICY "admins_read_creator_applications"
ON public.creator_applications
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "creator_ops_update_creator_applications" ON public.creator_applications;
CREATE POLICY "creator_ops_update_creator_applications"
ON public.creator_applications
FOR UPDATE
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'creator_ops']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'creator_ops']));

DROP POLICY IF EXISTS "admins_read_creator_referrals" ON public.creator_referrals;
CREATE POLICY "admins_read_creator_referrals"
ON public.creator_referrals
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "admins_read_creator_communications" ON public.creator_communications;
CREATE POLICY "admins_read_creator_communications"
ON public.creator_communications
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "creator_ops_manage_creator_communications" ON public.creator_communications;
CREATE POLICY "creator_ops_manage_creator_communications"
ON public.creator_communications
FOR ALL
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'creator_ops']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'creator_ops']));

DROP POLICY IF EXISTS "admins_read_creator_payouts" ON public.creator_payouts;
CREATE POLICY "admins_read_creator_payouts"
ON public.creator_payouts
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "creator_ops_manage_creator_payouts" ON public.creator_payouts;
CREATE POLICY "creator_ops_manage_creator_payouts"
ON public.creator_payouts
FOR ALL
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'creator_ops']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'creator_ops']));

DROP POLICY IF EXISTS "admins_read_waitlist_users" ON public.waitlist_users;
CREATE POLICY "admins_read_waitlist_users"
ON public.waitlist_users
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "admins_read_user_referrals" ON public.user_referrals;
CREATE POLICY "admins_read_user_referrals"
ON public.user_referrals
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "admins_read_city_status_logs" ON public.city_status_logs;
CREATE POLICY "admins_read_city_status_logs"
ON public.city_status_logs
FOR SELECT
TO authenticated
USING (public.has_admin_role(NULL));

DROP POLICY IF EXISTS "creator_ops_insert_city_status_logs" ON public.city_status_logs;
CREATE POLICY "creator_ops_insert_city_status_logs"
ON public.city_status_logs
FOR INSERT
TO authenticated
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'creator_ops']));
