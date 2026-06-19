CREATE OR REPLACE FUNCTION public.request_event_invite(p_event_id UUID, p_user_id UUID)
RETURNS public.event_rsvps
LANGUAGE plpgsql
AS $$
DECLARE
  v_row public.event_rsvps;
  v_event public.events%ROWTYPE;
  v_access_mode text;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'user mismatch';
  END IF;

  SELECT *
  INTO v_event
  FROM public.events
  WHERE id = p_event_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found';
  END IF;

  IF v_event.status = 'cancelled' THEN
    RAISE EXCEPTION 'event_cancelled';
  END IF;

  v_access_mode := COALESCE(v_event.access_mode, 'individual_request');

  IF v_access_mode = 'match_unlocked' AND NOT EXISTS (
    SELECT 1
    FROM public.matches m
    WHERE (m.user_1_id = auth.uid() OR m.user_2_id = auth.uid())
      AND m.status = 'chat_unlocked'
  ) THEN
    RAISE EXCEPTION 'match_required';
  END IF;

  SELECT *
  INTO v_row
  FROM public.event_rsvps
  WHERE event_id = p_event_id
    AND user_id = p_user_id
  LIMIT 1;

  IF FOUND THEN
    IF v_row.status = 'cancelled' THEN
      UPDATE public.event_rsvps
      SET status = 'requested',
          requested_at = now(),
          updated_at = now()
      WHERE id = v_row.id
      RETURNING * INTO v_row;
    END IF;

    RETURN v_row;
  END IF;

  INSERT INTO public.event_rsvps (event_id, user_id, status, requested_at)
  VALUES (p_event_id, p_user_id, 'requested', now())
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_event_invite(UUID, UUID) TO authenticated;
