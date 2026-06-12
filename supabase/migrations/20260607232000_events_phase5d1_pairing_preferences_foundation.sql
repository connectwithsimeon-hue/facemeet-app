ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS pairing_preferences_status TEXT NOT NULL DEFAULT 'closed';

ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_pairing_preferences_status_check;
ALTER TABLE public.events
  ADD CONSTRAINT events_pairing_preferences_status_check
  CHECK (pairing_preferences_status IN ('closed', 'open', 'locked'));

CREATE TABLE IF NOT EXISTS public.event_pairing_preferences (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  open_to_new_intro BOOLEAN NOT NULL DEFAULT false,
  attend_with_open_social_access BOOLEAN NOT NULL DEFAULT false,
  submitted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT event_pairing_preferences_event_user_key UNIQUE (event_id, user_id)
);

ALTER TABLE public.event_pairing_preferences
  DROP CONSTRAINT IF EXISTS event_pairing_preferences_open_social_exclusive_check;
ALTER TABLE public.event_pairing_preferences
  ADD CONSTRAINT event_pairing_preferences_open_social_exclusive_check
  CHECK (
    NOT attend_with_open_social_access
    OR open_to_new_intro = false
  );

CREATE INDEX IF NOT EXISTS idx_event_pairing_preferences_event_user
  ON public.event_pairing_preferences(event_id, user_id);

CREATE TABLE IF NOT EXISTS public.event_pairing_preference_matches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  preference_id UUID NOT NULL REFERENCES public.event_pairing_preferences(id) ON DELETE CASCADE,
  match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT event_pairing_preference_matches_preference_match_key UNIQUE (preference_id, match_id)
);

CREATE INDEX IF NOT EXISTS idx_event_pairing_preference_matches_preference
  ON public.event_pairing_preference_matches(preference_id, created_at);

CREATE OR REPLACE FUNCTION public.set_event_pairing_preferences_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_event_pairing_preferences_updated_at ON public.event_pairing_preferences;
CREATE TRIGGER set_event_pairing_preferences_updated_at
BEFORE UPDATE ON public.event_pairing_preferences
FOR EACH ROW
EXECUTE FUNCTION public.set_event_pairing_preferences_updated_at();

ALTER TABLE public.event_pairing_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_pairing_preference_matches ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.get_my_event_pairing_preferences(
  p_event_id UUID
)
RETURNS TABLE (
  event_id UUID,
  pairing_preferences_status TEXT,
  open_to_new_intro BOOLEAN,
  attend_with_open_social_access BOOLEAN,
  submitted_at TIMESTAMPTZ,
  selected_match_ids UUID[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  RETURN QUERY
  SELECT
    e.id,
    e.pairing_preferences_status,
    COALESCE(epp.open_to_new_intro, false),
    COALESCE(epp.attend_with_open_social_access, false),
    epp.submitted_at,
    COALESCE((
      SELECT array_agg(epm.match_id ORDER BY epm.created_at, epm.match_id)
      FROM public.event_pairing_preference_matches epm
      WHERE epm.preference_id = epp.id
    ), ARRAY[]::UUID[])
  FROM public.events e
  LEFT JOIN public.event_pairing_preferences epp
    ON epp.event_id = e.id
   AND epp.user_id = v_user_id
  WHERE e.id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_eligible_event_matches(
  p_event_id UUID
)
RETURNS TABLE (
  match_id UUID,
  other_user_first_name TEXT,
  other_user_username TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  PERFORM 1
  FROM public.events
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.event_rsvps er
    WHERE er.event_id = p_event_id
      AND er.user_id = v_user_id
      AND er.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'attendee_not_approved';
  END IF;

  RETURN QUERY
  SELECT
    m.id AS match_id,
    NULLIF(BTRIM(other_user.first_name), '') AS other_user_first_name,
    NULLIF(BTRIM(other_user.username), '') AS other_user_username
  FROM public.matches m
  JOIN public.users other_user
    ON other_user.id = CASE
      WHEN m.user_1_id = v_user_id THEN m.user_2_id
      ELSE m.user_1_id
    END
  WHERE m.status = 'chat_unlocked'
    AND (m.user_1_id = v_user_id OR m.user_2_id = v_user_id)
  ORDER BY
    COALESCE(NULLIF(BTRIM(other_user.first_name), ''), NULLIF(BTRIM(other_user.username), ''), '') ASC,
    m.created_at ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.save_my_event_pairing_preferences(
  p_event_id UUID,
  p_open_to_new_intro BOOLEAN,
  p_attend_with_open_social_access BOOLEAN,
  p_selected_match_ids UUID[]
)
RETURNS TABLE (
  event_id UUID,
  saved BOOLEAN,
  selected_match_count INTEGER,
  open_to_new_intro BOOLEAN,
  attend_with_open_social_access BOOLEAN,
  submitted_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_preference_id UUID;
  v_now TIMESTAMPTZ := now();
  v_selected_match_ids UUID[] := ARRAY[]::UUID[];
  v_selected_match_count INTEGER := 0;
  v_valid_match_count INTEGER := 0;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  PERFORM 1
  FROM public.events e
  WHERE e.id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_event_id::text || ':' || v_user_id::text, 0)
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.events e
    WHERE e.id = p_event_id
      AND e.pairing_preferences_status = 'open'
  ) THEN
    RAISE EXCEPTION 'pairing_preferences_not_open';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.event_rsvps er
    WHERE er.event_id = p_event_id
      AND er.user_id = v_user_id
      AND er.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'attendee_not_approved';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.event_rsvps er
    WHERE er.event_id = p_event_id
      AND er.user_id = v_user_id
      AND er.pairing_released_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'pair_ticket_already_released';
  END IF;

  SELECT COALESCE(array_agg(DISTINCT selected_match_id), ARRAY[]::UUID[])
  INTO v_selected_match_ids
  FROM unnest(COALESCE(p_selected_match_ids, ARRAY[]::UUID[])) AS selected_match_id;

  v_selected_match_count := COALESCE(array_length(v_selected_match_ids, 1), 0);

  IF p_attend_with_open_social_access AND (
    p_open_to_new_intro
    OR v_selected_match_count > 0
  ) THEN
    RAISE EXCEPTION 'open_social_access_must_be_exclusive';
  END IF;

  IF v_selected_match_count > 3 THEN
    RAISE EXCEPTION 'too_many_selected_matches';
  END IF;

  IF NOT p_open_to_new_intro
     AND NOT p_attend_with_open_social_access
     AND v_selected_match_count = 0 THEN
    RAISE EXCEPTION 'pairing_preference_required';
  END IF;

  IF v_selected_match_count > 0 THEN
    SELECT COUNT(*)::INTEGER
    INTO v_valid_match_count
    FROM public.matches m
    WHERE m.id = ANY(v_selected_match_ids)
      AND m.status = 'chat_unlocked'
      AND (m.user_1_id = v_user_id OR m.user_2_id = v_user_id);

    IF v_valid_match_count <> v_selected_match_count THEN
      RAISE EXCEPTION 'invalid_selected_match';
    END IF;
  END IF;

  INSERT INTO public.event_pairing_preferences (
    event_id,
    user_id,
    open_to_new_intro,
    attend_with_open_social_access,
    submitted_at,
    updated_at
  )
  VALUES (
    p_event_id,
    v_user_id,
    p_open_to_new_intro,
    p_attend_with_open_social_access,
    v_now,
    v_now
  )
  ON CONFLICT (event_id, user_id) DO UPDATE
    SET open_to_new_intro = EXCLUDED.open_to_new_intro,
        attend_with_open_social_access = EXCLUDED.attend_with_open_social_access,
        submitted_at = EXCLUDED.submitted_at,
        updated_at = EXCLUDED.updated_at
  RETURNING id INTO v_preference_id;

  DELETE FROM public.event_pairing_preference_matches
  WHERE preference_id = v_preference_id;

  IF v_selected_match_count > 0 THEN
    INSERT INTO public.event_pairing_preference_matches (
      preference_id,
      match_id
    )
    SELECT v_preference_id, selected_match_id
    FROM unnest(v_selected_match_ids) AS selected_match_id;
  END IF;

  RETURN QUERY
  SELECT
    p_event_id,
    true,
    v_selected_match_count,
    p_open_to_new_intro,
    p_attend_with_open_social_access,
    v_now;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_get_event_pairing_preferences(
  p_event_id UUID
)
RETURNS TABLE (
  event_id UUID,
  attendee_user_id UUID,
  attendee_first_name TEXT,
  attendee_username TEXT,
  preferences_submitted BOOLEAN,
  open_to_new_intro BOOLEAN,
  attend_with_open_social_access BOOLEAN,
  submitted_at TIMESTAMPTZ,
  selected_match_count INTEGER,
  selected_matches JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'events_ops']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  PERFORM 1
  FROM public.events
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found';
  END IF;

  RETURN QUERY
  SELECT
    p_event_id,
    u.id,
    u.first_name,
    u.username,
    epp.id IS NOT NULL AND epp.submitted_at IS NOT NULL,
    COALESCE(epp.open_to_new_intro, false),
    COALESCE(epp.attend_with_open_social_access, false),
    epp.submitted_at,
    COALESCE(matches_json.selected_match_count, 0),
    COALESCE(matches_json.selected_matches, '[]'::JSONB)
  FROM public.event_rsvps er
  JOIN public.users u ON u.id = er.user_id
  LEFT JOIN public.event_pairing_preferences epp
    ON epp.event_id = er.event_id
   AND epp.user_id = er.user_id
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*)::INTEGER AS selected_match_count,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'match_id', m.id,
            'other_user_first_name', other_user.first_name,
            'other_user_username', other_user.username
          )
          ORDER BY epm.created_at, epm.id
        ),
        '[]'::JSONB
      ) AS selected_matches
    FROM public.event_pairing_preference_matches epm
    JOIN public.matches m ON m.id = epm.match_id
    JOIN public.users other_user
      ON other_user.id = CASE
        WHEN m.user_1_id = er.user_id THEN m.user_2_id
        ELSE m.user_1_id
      END
    WHERE epm.preference_id = epp.id
  ) AS matches_json ON epp.id IS NOT NULL
  WHERE er.event_id = p_event_id
    AND er.status = 'approved'
  ORDER BY COALESCE(NULLIF(BTRIM(u.first_name), ''), NULLIF(BTRIM(u.username), ''), '') ASC, u.created_at ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_event_pairing_preferences_status(
  p_event_id UUID,
  p_status TEXT
)
RETURNS TABLE (
  event_id UUID,
  pairing_preferences_status TEXT,
  updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_now TIMESTAMPTZ := now();
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'events_ops']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  IF p_status NOT IN ('closed', 'open', 'locked') THEN
    RAISE EXCEPTION 'invalid_pairing_preferences_status';
  END IF;

  PERFORM 1
  FROM public.events
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));

  IF p_status = 'open' AND (
    EXISTS (
      SELECT 1
      FROM public.event_anchor_pairs eap
      WHERE eap.event_id = p_event_id
        AND eap.status = 'released'
        AND eap.released_at IS NOT NULL
    )
    OR EXISTS (
      SELECT 1
      FROM public.event_rsvps er
      WHERE er.event_id = p_event_id
        AND er.status = 'approved'
        AND er.pairing_released_at IS NOT NULL
    )
  ) THEN
    RAISE EXCEPTION 'pair_tickets_already_released';
  END IF;

  UPDATE public.events e
  SET pairing_preferences_status = p_status,
      updated_at = v_now
  WHERE e.id = p_event_id;

  PERFORM public.log_admin_action(
    'set_event_pairing_preferences_status',
    'event',
    p_event_id::text,
    jsonb_build_object('pairing_preferences_status', p_status)
  );

  RETURN QUERY
  SELECT e.id, e.pairing_preferences_status, e.updated_at
  FROM public.events e
  WHERE e.id = p_event_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_release_event_pairing_results(
  p_event_id UUID
)
RETURNS TABLE (
  released_pair_count INTEGER,
  released_paired_attendee_count INTEGER,
  released_open_social_count INTEGER,
  unassigned_attendee_count INTEGER,
  draft_pair_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_now TIMESTAMPTZ := now();
  v_pairing_preferences_status TEXT;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'events_ops']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  SELECT e.pairing_preferences_status
  INTO v_pairing_preferences_status
  FROM public.events e
  WHERE e.id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found';
  END IF;

  IF v_pairing_preferences_status = 'open' THEN
    RAISE EXCEPTION 'pairing_preferences_still_open';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));

  UPDATE public.event_anchor_pairs
  SET status = 'released',
      released_at = COALESCE(released_at, v_now),
      updated_at = v_now
  WHERE event_id = p_event_id
    AND status = 'confirmed';

  UPDATE public.event_rsvps er
  SET pairing_released_at = COALESCE(er.pairing_released_at, v_now),
      updated_at = v_now
  WHERE er.event_id = p_event_id
    AND er.status = 'approved'
    AND (
      er.pairing_status = 'open_social_access'
      OR (
        er.pairing_status = 'paired'
        AND EXISTS (
          SELECT 1
          FROM public.event_anchor_pairs eap
          WHERE eap.event_id = er.event_id
            AND eap.status = 'released'
            AND eap.released_at IS NOT NULL
            AND (eap.user_1_id = er.user_id OR eap.user_2_id = er.user_id)
        )
      )
    );

  PERFORM public.log_admin_action(
    'release_event_pairing_results',
    'event',
    p_event_id::text,
    jsonb_build_object('released_at', v_now)
  );

  RETURN QUERY
  SELECT
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.event_anchor_pairs eap
      WHERE eap.event_id = p_event_id
        AND eap.status = 'released'
        AND eap.released_at IS NOT NULL
    ), 0),
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.event_rsvps er
      WHERE er.event_id = p_event_id
        AND er.status = 'approved'
        AND er.pairing_status = 'paired'
        AND er.pairing_released_at IS NOT NULL
    ), 0),
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.event_rsvps er
      WHERE er.event_id = p_event_id
        AND er.status = 'approved'
        AND er.pairing_status = 'open_social_access'
        AND er.pairing_released_at IS NOT NULL
    ), 0),
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.event_rsvps er
      WHERE er.event_id = p_event_id
        AND er.status = 'approved'
        AND er.pairing_status = 'unassigned'
    ), 0),
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.event_anchor_pairs eap
      WHERE eap.event_id = p_event_id
        AND eap.status = 'draft'
    ), 0);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_event_pairing_preferences(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_eligible_event_matches(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_my_event_pairing_preferences(UUID, BOOLEAN, BOOLEAN, UUID[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_event_pairing_preferences(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_event_pairing_preferences_status(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_release_event_pairing_results(UUID) TO authenticated;
