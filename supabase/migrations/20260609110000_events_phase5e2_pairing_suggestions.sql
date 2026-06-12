CREATE OR REPLACE FUNCTION public.admin_get_event_pairing_suggestions(
  p_event_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_payload JSONB;
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

  WITH approved_attendees AS (
    SELECT
      er.user_id,
      er.pairing_status,
      er.pairing_released_at,
      COALESCE(NULLIF(BTRIM(u.first_name), ''), NULLIF(BTRIM(u.username), ''), 'Attendee') AS attendee_name
    FROM public.event_rsvps er
    JOIN public.users u
      ON u.id = er.user_id
    WHERE er.event_id = p_event_id
      AND er.status = 'approved'
  ),
  attendees_with_active_pairs AS (
    SELECT eap.user_1_id AS user_id
    FROM public.event_anchor_pairs eap
    WHERE eap.event_id = p_event_id
      AND eap.status <> 'cancelled'
    UNION
    SELECT eap.user_2_id AS user_id
    FROM public.event_anchor_pairs eap
    WHERE eap.event_id = p_event_id
      AND eap.status <> 'cancelled'
  ),
  eligible_attendees AS (
    SELECT
      aa.user_id,
      aa.attendee_name
    FROM approved_attendees aa
    WHERE aa.pairing_status = 'unassigned'
      AND aa.pairing_released_at IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM attendees_with_active_pairs ap
        WHERE ap.user_id = aa.user_id
      )
  ),
  submitted_preferences AS (
    SELECT
      epp.id AS preference_id,
      epp.user_id,
      epp.open_to_new_intro,
      epp.attend_with_open_social_access,
      epp.submitted_at
    FROM public.event_pairing_preferences epp
    JOIN approved_attendees aa
      ON aa.user_id = epp.user_id
    WHERE epp.event_id = p_event_id
      AND epp.submitted_at IS NOT NULL
  ),
  directed_interest AS (
    SELECT
      sp.user_id AS selected_by_user_id,
      selected_by.attendee_name AS selected_by_name,
      other_attendee.user_id AS other_user_id,
      other_attendee.attendee_name AS other_user_name,
      m.id AS match_id
    FROM submitted_preferences sp
    JOIN eligible_attendees selected_by
      ON selected_by.user_id = sp.user_id
    JOIN public.event_pairing_preference_matches epm
      ON epm.preference_id = sp.preference_id
    JOIN public.matches m
      ON m.id = epm.match_id
    JOIN eligible_attendees other_attendee
      ON other_attendee.user_id = CASE
        WHEN m.user_1_id = sp.user_id THEN m.user_2_id
        ELSE m.user_1_id
      END
    WHERE sp.attend_with_open_social_access = false
  ),
  reciprocal_suggestions AS (
    SELECT DISTINCT
      CASE
        WHEN di.selected_by_user_id::TEXT <= di.other_user_id::TEXT THEN di.selected_by_user_id
        ELSE di.other_user_id
      END AS user_1_id,
      CASE
        WHEN di.selected_by_user_id::TEXT <= di.other_user_id::TEXT THEN di.selected_by_name
        ELSE di.other_user_name
      END AS user_1_name,
      CASE
        WHEN di.selected_by_user_id::TEXT <= di.other_user_id::TEXT THEN di.other_user_id
        ELSE di.selected_by_user_id
      END AS user_2_id,
      CASE
        WHEN di.selected_by_user_id::TEXT <= di.other_user_id::TEXT THEN di.other_user_name
        ELSE di.selected_by_name
      END AS user_2_name,
      di.match_id,
      'reciprocal_interest'::TEXT AS suggestion_type
    FROM directed_interest di
    WHERE EXISTS (
      SELECT 1
      FROM directed_interest reverse_di
      WHERE reverse_di.match_id = di.match_id
        AND reverse_di.selected_by_user_id = di.other_user_id
        AND reverse_di.other_user_id = di.selected_by_user_id
    )
  ),
  one_sided_suggestions AS (
    SELECT
      di.selected_by_user_id,
      di.selected_by_name,
      di.other_user_id,
      di.other_user_name,
      di.match_id,
      'one_sided_interest'::TEXT AS suggestion_type
    FROM directed_interest di
    WHERE NOT EXISTS (
      SELECT 1
      FROM directed_interest reverse_di
      WHERE reverse_di.match_id = di.match_id
        AND reverse_di.selected_by_user_id = di.other_user_id
        AND reverse_di.other_user_id = di.selected_by_user_id
    )
  ),
  open_to_new_intro_pool AS (
    SELECT
      ea.user_id,
      ea.attendee_name AS first_name,
      sp.submitted_at
    FROM submitted_preferences sp
    JOIN eligible_attendees ea
      ON ea.user_id = sp.user_id
    WHERE sp.open_to_new_intro = true
      AND sp.attend_with_open_social_access = false
  )
  SELECT jsonb_build_object(
    'reciprocal_suggestions',
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'user_1_id', rs.user_1_id,
          'user_1_name', rs.user_1_name,
          'user_2_id', rs.user_2_id,
          'user_2_name', rs.user_2_name,
          'match_id', rs.match_id,
          'suggestion_type', rs.suggestion_type
        )
        ORDER BY rs.user_1_name, rs.user_2_name
      )
      FROM reciprocal_suggestions rs
    ), '[]'::JSONB),
    'one_sided_suggestions',
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'selected_by_user_id', os.selected_by_user_id,
          'selected_by_name', os.selected_by_name,
          'other_user_id', os.other_user_id,
          'other_user_name', os.other_user_name,
          'match_id', os.match_id,
          'suggestion_type', os.suggestion_type
        )
        ORDER BY os.selected_by_name, os.other_user_name
      )
      FROM one_sided_suggestions os
    ), '[]'::JSONB),
    'open_to_new_intro_pool',
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'user_id', op.user_id,
          'first_name', op.first_name,
          'submitted_at', op.submitted_at
        )
        ORDER BY op.first_name, op.submitted_at
      )
      FROM open_to_new_intro_pool op
    ), '[]'::JSONB)
  )
  INTO v_payload;

  RETURN COALESCE(v_payload, jsonb_build_object(
    'reciprocal_suggestions', '[]'::JSONB,
    'one_sided_suggestions', '[]'::JSONB,
    'open_to_new_intro_pool', '[]'::JSONB
  ));
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_event_pairing_suggestions(UUID) TO authenticated;
