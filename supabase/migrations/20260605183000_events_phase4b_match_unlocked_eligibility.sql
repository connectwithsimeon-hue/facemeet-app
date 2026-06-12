CREATE OR REPLACE FUNCTION public.request_event_invite(p_event_id UUID, p_user_id UUID)
RETURNS public.event_rsvps
LANGUAGE plpgsql
AS $$
DECLARE
  v_row public.event_rsvps;
  v_access_mode text;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'user mismatch';
  END IF;

  SELECT *
  INTO v_row
  FROM public.event_rsvps
  WHERE event_id = p_event_id
    AND user_id = p_user_id
  LIMIT 1;

  IF FOUND THEN
    RETURN v_row;
  END IF;

  SELECT access_mode
  INTO v_access_mode
  FROM public.events
  WHERE id = p_event_id
  LIMIT 1;

  IF COALESCE(v_access_mode, 'individual_request') = 'match_unlocked' AND NOT EXISTS (
    SELECT 1
    FROM public.matches m
    WHERE (m.user_1_id = auth.uid() OR m.user_2_id = auth.uid())
      AND m.status = 'chat_unlocked'
  ) THEN
    RAISE EXCEPTION 'match_required';
  END IF;

  INSERT INTO public.event_rsvps (event_id, user_id, status, requested_at)
  VALUES (p_event_id, p_user_id, 'requested', now())
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;
