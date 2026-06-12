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
            'match_id', selected_match.match_id,
            'other_user_first_name', selected_match.other_user_first_name,
            'other_user_username', selected_match.other_user_username,
            'is_reciprocal', selected_match.is_reciprocal
          )
          ORDER BY selected_match.created_at, selected_match.preference_match_id
        ),
        '[]'::JSONB
      ) AS selected_matches
    FROM (
      SELECT
        epm.id AS preference_match_id,
        epm.created_at,
        m.id AS match_id,
        other_user.id AS other_user_id,
        other_user.first_name AS other_user_first_name,
        other_user.username AS other_user_username,
        EXISTS (
          SELECT 1
          FROM public.event_rsvps er_other
          JOIN public.event_pairing_preferences epp_other
            ON epp_other.event_id = er_other.event_id
           AND epp_other.user_id = er_other.user_id
          JOIN public.event_pairing_preference_matches epm_other
            ON epm_other.preference_id = epp_other.id
          WHERE er_other.event_id = p_event_id
            AND er_other.status = 'approved'
            AND er_other.user_id = other_user.id
            AND epm_other.match_id = m.id
        ) AS is_reciprocal
      FROM public.event_pairing_preference_matches epm
      JOIN public.matches m ON m.id = epm.match_id
      JOIN public.users other_user
        ON other_user.id = CASE
          WHEN m.user_1_id = er.user_id THEN m.user_2_id
          ELSE m.user_1_id
        END
      WHERE epm.preference_id = epp.id
    ) AS selected_match
  ) AS matches_json ON epp.id IS NOT NULL
  WHERE er.event_id = p_event_id
    AND er.status = 'approved'
  ORDER BY COALESCE(NULLIF(BTRIM(u.first_name), ''), NULLIF(BTRIM(u.username), ''), '') ASC, u.created_at ASC;
END;
$$;
