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
    AND EXISTS (
      SELECT 1
      FROM public.event_rsvps er_other
      WHERE er_other.event_id = p_event_id
        AND er_other.user_id = other_user.id
        AND er_other.status = 'approved'
    )
  ORDER BY
    COALESCE(NULLIF(BTRIM(other_user.first_name), ''), NULLIF(BTRIM(other_user.username), ''), '') ASC,
    m.created_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_eligible_event_matches(UUID) TO authenticated;
