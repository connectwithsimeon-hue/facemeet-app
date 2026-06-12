CREATE TABLE IF NOT EXISTS public.event_anchor_pairs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  pair_number INTEGER NOT NULL,
  user_1_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  user_2_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  source_match_id UUID REFERENCES public.matches(id) ON DELETE SET NULL,
  pair_source TEXT NOT NULL DEFAULT 'manual_admin',
  status TEXT NOT NULL DEFAULT 'draft',
  confirmed_by_admin_id UUID REFERENCES public.admin_users(id) ON DELETE SET NULL,
  confirmed_at TIMESTAMPTZ,
  released_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.event_anchor_pairs
  DROP CONSTRAINT IF EXISTS event_anchor_pairs_pair_number_check;
ALTER TABLE public.event_anchor_pairs
  ADD CONSTRAINT event_anchor_pairs_pair_number_check
  CHECK (pair_number > 0);

ALTER TABLE public.event_anchor_pairs
  DROP CONSTRAINT IF EXISTS event_anchor_pairs_distinct_users_check;
ALTER TABLE public.event_anchor_pairs
  ADD CONSTRAINT event_anchor_pairs_distinct_users_check
  CHECK (user_1_id <> user_2_id);

ALTER TABLE public.event_anchor_pairs
  DROP CONSTRAINT IF EXISTS event_anchor_pairs_pair_source_check;
ALTER TABLE public.event_anchor_pairs
  ADD CONSTRAINT event_anchor_pairs_pair_source_check
  CHECK (pair_source IN ('existing_match', 'manual_admin', 'recommended_new_intro'));

ALTER TABLE public.event_anchor_pairs
  DROP CONSTRAINT IF EXISTS event_anchor_pairs_status_check;
ALTER TABLE public.event_anchor_pairs
  ADD CONSTRAINT event_anchor_pairs_status_check
  CHECK (status IN ('draft', 'confirmed', 'released', 'cancelled'));

ALTER TABLE public.event_anchor_pairs
  DROP CONSTRAINT IF EXISTS event_anchor_pairs_event_id_pair_number_key;
ALTER TABLE public.event_anchor_pairs
  ADD CONSTRAINT event_anchor_pairs_event_id_pair_number_key
  UNIQUE (event_id, pair_number);

CREATE INDEX IF NOT EXISTS idx_event_anchor_pairs_event_status
  ON public.event_anchor_pairs(event_id, status, pair_number);

CREATE INDEX IF NOT EXISTS idx_event_anchor_pairs_user_1_active
  ON public.event_anchor_pairs(event_id, user_1_id)
  WHERE status <> 'cancelled';

CREATE INDEX IF NOT EXISTS idx_event_anchor_pairs_user_2_active
  ON public.event_anchor_pairs(event_id, user_2_id)
  WHERE status <> 'cancelled';

ALTER TABLE public.event_rsvps
  ADD COLUMN IF NOT EXISTS pairing_status TEXT NOT NULL DEFAULT 'unassigned';

ALTER TABLE public.event_rsvps
  DROP CONSTRAINT IF EXISTS event_rsvps_pairing_status_check;
ALTER TABLE public.event_rsvps
  ADD CONSTRAINT event_rsvps_pairing_status_check
  CHECK (pairing_status IN ('unassigned', 'open_social_access', 'paired'));

CREATE OR REPLACE FUNCTION public.set_event_anchor_pairs_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_event_anchor_pairs_updated_at ON public.event_anchor_pairs;
CREATE TRIGGER set_event_anchor_pairs_updated_at
BEFORE UPDATE ON public.event_anchor_pairs
FOR EACH ROW
EXECUTE FUNCTION public.set_event_anchor_pairs_updated_at();

ALTER TABLE public.event_anchor_pairs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admins_read_event_anchor_pairs" ON public.event_anchor_pairs;
CREATE POLICY "admins_read_event_anchor_pairs"
ON public.event_anchor_pairs
FOR SELECT
TO authenticated
USING (
  public.has_admin_role(ARRAY['super_admin', 'events_ops', 'moderator', 'support_staff'])
);

CREATE OR REPLACE FUNCTION public.admin_create_event_anchor_pair(
  p_event_id UUID,
  p_user_1_id UUID,
  p_user_2_id UUID,
  p_pair_source TEXT DEFAULT 'manual_admin',
  p_source_match_id UUID DEFAULT NULL
)
RETURNS public.event_anchor_pairs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_pair public.event_anchor_pairs;
  v_pair_number INTEGER;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'events_ops']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));

  IF p_user_1_id = p_user_2_id THEN
    RAISE EXCEPTION 'anchor_pair_users_must_differ';
  END IF;

  IF p_pair_source NOT IN ('existing_match', 'manual_admin', 'recommended_new_intro') THEN
    RAISE EXCEPTION 'invalid_pair_source';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.event_rsvps er
    WHERE er.event_id = p_event_id
      AND er.user_id = p_user_1_id
      AND er.status = 'approved'
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.event_rsvps er
    WHERE er.event_id = p_event_id
      AND er.user_id = p_user_2_id
      AND er.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'approved_rsvp_required';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.event_rsvps er
    WHERE er.event_id = p_event_id
      AND er.user_id IN (p_user_1_id, p_user_2_id)
      AND er.pairing_status = 'open_social_access'
  ) THEN
    RAISE EXCEPTION 'open_social_access_conflict';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.event_anchor_pairs eap
    WHERE eap.event_id = p_event_id
      AND eap.status <> 'cancelled'
      AND (
        eap.user_1_id IN (p_user_1_id, p_user_2_id)
        OR eap.user_2_id IN (p_user_1_id, p_user_2_id)
      )
  ) THEN
    RAISE EXCEPTION 'attendee_already_paired';
  END IF;

  IF p_source_match_id IS NULL AND p_pair_source = 'existing_match' THEN
    RAISE EXCEPTION 'source_match_required';
  END IF;

  IF p_source_match_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.matches m
    WHERE m.id = p_source_match_id
      AND m.status = 'chat_unlocked'
      AND (
        (m.user_1_id = p_user_1_id AND m.user_2_id = p_user_2_id)
        OR (m.user_1_id = p_user_2_id AND m.user_2_id = p_user_1_id)
      )
  ) THEN
    RAISE EXCEPTION 'invalid_source_match';
  END IF;

  SELECT COALESCE(MAX(eap.pair_number), 0) + 1
  INTO v_pair_number
  FROM public.event_anchor_pairs eap
  WHERE eap.event_id = p_event_id;

  INSERT INTO public.event_anchor_pairs (
    event_id,
    pair_number,
    user_1_id,
    user_2_id,
    source_match_id,
    pair_source,
    status
  )
  VALUES (
    p_event_id,
    v_pair_number,
    p_user_1_id,
    p_user_2_id,
    p_source_match_id,
    p_pair_source,
    'draft'
  )
  RETURNING * INTO v_pair;

  UPDATE public.event_rsvps
  SET pairing_status = 'paired',
      updated_at = now()
  WHERE event_id = p_event_id
    AND user_id IN (p_user_1_id, p_user_2_id);

  PERFORM public.log_admin_action(
    'create_event_anchor_pair',
    'event_anchor_pair',
    v_pair.id::text,
    jsonb_build_object(
      'event_id', p_event_id,
      'pair_number', v_pair.pair_number,
      'user_1_id', p_user_1_id,
      'user_2_id', p_user_2_id,
      'pair_source', p_pair_source,
      'source_match_id', p_source_match_id
    )
  );

  RETURN v_pair;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_cancel_event_anchor_pair(
  p_pair_id UUID
)
RETURNS public.event_anchor_pairs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_pair public.event_anchor_pairs;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'events_ops']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  SELECT *
  INTO v_pair
  FROM public.event_anchor_pairs
  WHERE id = p_pair_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'anchor_pair_not_found';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_pair.event_id::text, 0));

  UPDATE public.event_anchor_pairs
  SET status = 'cancelled',
      updated_at = now()
  WHERE id = p_pair_id
  RETURNING * INTO v_pair;

  UPDATE public.event_rsvps er
  SET pairing_status = CASE
        WHEN EXISTS (
          SELECT 1
          FROM public.event_anchor_pairs eap
          WHERE eap.event_id = v_pair.event_id
            AND eap.id <> v_pair.id
            AND eap.status <> 'cancelled'
            AND (eap.user_1_id = er.user_id OR eap.user_2_id = er.user_id)
        ) THEN 'paired'
        ELSE 'unassigned'
      END,
      updated_at = now()
  WHERE er.event_id = v_pair.event_id
    AND er.user_id IN (v_pair.user_1_id, v_pair.user_2_id);

  PERFORM public.log_admin_action(
    'cancel_event_anchor_pair',
    'event_anchor_pair',
    v_pair.id::text,
    jsonb_build_object(
      'event_id', v_pair.event_id,
      'pair_number', v_pair.pair_number,
      'user_1_id', v_pair.user_1_id,
      'user_2_id', v_pair.user_2_id
    )
  );

  RETURN v_pair;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_event_open_social_access(
  p_event_id UUID,
  p_user_id UUID
)
RETURNS public.event_rsvps
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_rsvp public.event_rsvps;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'events_ops']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));

  IF NOT EXISTS (
    SELECT 1
    FROM public.event_rsvps er
    WHERE er.event_id = p_event_id
      AND er.user_id = p_user_id
      AND er.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'approved_rsvp_required';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.event_anchor_pairs eap
    WHERE eap.event_id = p_event_id
      AND eap.status <> 'cancelled'
      AND (eap.user_1_id = p_user_id OR eap.user_2_id = p_user_id)
  ) THEN
    RAISE EXCEPTION 'attendee_already_paired';
  END IF;

  UPDATE public.event_rsvps
  SET pairing_status = 'open_social_access',
      updated_at = now()
  WHERE event_id = p_event_id
    AND user_id = p_user_id
  RETURNING * INTO v_rsvp;

  PERFORM public.log_admin_action(
    'set_event_open_social_access',
    'event_rsvp',
    v_rsvp.id::text,
    jsonb_build_object(
      'event_id', p_event_id,
      'user_id', p_user_id,
      'pairing_status', 'open_social_access'
    )
  );

  RETURN v_rsvp;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reset_event_pairing_status(
  p_event_id UUID,
  p_user_id UUID
)
RETURNS public.event_rsvps
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_rsvp public.event_rsvps;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'events_ops']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));

  IF NOT EXISTS (
    SELECT 1
    FROM public.event_rsvps er
    WHERE er.event_id = p_event_id
      AND er.user_id = p_user_id
      AND er.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'approved_rsvp_required';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.event_anchor_pairs eap
    WHERE eap.event_id = p_event_id
      AND eap.status <> 'cancelled'
      AND (eap.user_1_id = p_user_id OR eap.user_2_id = p_user_id)
  ) THEN
    RAISE EXCEPTION 'attendee_already_paired';
  END IF;

  UPDATE public.event_rsvps
  SET pairing_status = 'unassigned',
      updated_at = now()
  WHERE event_id = p_event_id
    AND user_id = p_user_id
  RETURNING * INTO v_rsvp;

  PERFORM public.log_admin_action(
    'reset_event_pairing_status',
    'event_rsvp',
    v_rsvp.id::text,
    jsonb_build_object(
      'event_id', p_event_id,
      'user_id', p_user_id,
      'pairing_status', 'unassigned'
    )
  );

  RETURN v_rsvp;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_confirm_event_anchor_pair(
  p_pair_id UUID
)
RETURNS public.event_anchor_pairs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_pair public.event_anchor_pairs;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'events_ops']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  SELECT *
  INTO v_pair
  FROM public.event_anchor_pairs
  WHERE id = p_pair_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'anchor_pair_not_found';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_pair.event_id::text, 0));

  IF v_pair.status <> 'draft' THEN
    RAISE EXCEPTION 'anchor_pair_not_draft';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.event_rsvps er
    WHERE er.event_id = v_pair.event_id
      AND er.user_id = v_pair.user_1_id
      AND er.status = 'approved'
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.event_rsvps er
    WHERE er.event_id = v_pair.event_id
      AND er.user_id = v_pair.user_2_id
      AND er.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'approved_rsvp_required';
  END IF;

  UPDATE public.event_anchor_pairs
  SET status = 'confirmed',
      confirmed_by_admin_id = v_admin_user_id,
      confirmed_at = now(),
      updated_at = now()
  WHERE id = p_pair_id
  RETURNING * INTO v_pair;

  PERFORM public.log_admin_action(
    'confirm_event_anchor_pair',
    'event_anchor_pair',
    v_pair.id::text,
    jsonb_build_object(
      'event_id', v_pair.event_id,
      'pair_number', v_pair.pair_number,
      'user_1_id', v_pair.user_1_id,
      'user_2_id', v_pair.user_2_id
    )
  );

  RETURN v_pair;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_event_anchor_pair(UUID, UUID, UUID, TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_cancel_event_anchor_pair(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_event_open_social_access(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reset_event_pairing_status(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_confirm_event_anchor_pair(UUID) TO authenticated;
