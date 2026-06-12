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
  FROM public.events AS e
  WHERE e.id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_event_id::text || ':' || v_user_id::text, 0)
  );

  IF NOT EXISTS (
    SELECT 1
    FROM public.events AS e
    WHERE e.id = p_event_id
      AND e.pairing_preferences_status = 'open'
  ) THEN
    RAISE EXCEPTION 'pairing_preferences_not_open';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.event_rsvps AS er
    WHERE er.event_id = p_event_id
      AND er.user_id = v_user_id
      AND er.status = 'approved'
  ) THEN
    RAISE EXCEPTION 'attendee_not_approved';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.event_rsvps AS er
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
    FROM public.matches AS m
    WHERE m.id = ANY(v_selected_match_ids)
      AND m.status = 'chat_unlocked'
      AND (m.user_1_id = v_user_id OR m.user_2_id = v_user_id);

    IF v_valid_match_count <> v_selected_match_count THEN
      RAISE EXCEPTION 'invalid_selected_match';
    END IF;
  END IF;

  INSERT INTO public.event_pairing_preferences AS pref (
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
  ON CONFLICT ON CONSTRAINT event_pairing_preferences_event_user_key DO UPDATE
    SET open_to_new_intro = EXCLUDED.open_to_new_intro,
        attend_with_open_social_access = EXCLUDED.attend_with_open_social_access,
        submitted_at = EXCLUDED.submitted_at,
        updated_at = EXCLUDED.updated_at
  RETURNING pref.id INTO v_preference_id;

  DELETE FROM public.event_pairing_preference_matches AS epm
  WHERE epm.preference_id = v_preference_id;

  IF v_selected_match_count > 0 THEN
    INSERT INTO public.event_pairing_preference_matches AS epm (
      preference_id,
      match_id
    )
    SELECT v_preference_id, selected_match_id
    FROM unnest(v_selected_match_ids) AS selected_match_id;
  END IF;

  RETURN QUERY
  SELECT
    p_event_id AS event_id,
    true AS saved,
    v_selected_match_count AS selected_match_count,
    p_open_to_new_intro AS open_to_new_intro,
    p_attend_with_open_social_access AS attend_with_open_social_access,
    v_now AS submitted_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.save_my_event_pairing_preferences(UUID, BOOLEAN, BOOLEAN, UUID[]) TO authenticated;
