CREATE OR REPLACE FUNCTION public.withdraw_event_request(p_event_id UUID)
RETURNS public.event_rsvps
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_event public.events%ROWTYPE;
  v_row public.event_rsvps;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  SELECT *
  INTO v_event
  FROM public.events
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found';
  END IF;

  IF v_event.status = 'cancelled' THEN
    RAISE EXCEPTION 'event_cancelled';
  END IF;

  SELECT *
  INTO v_row
  FROM public.event_rsvps
  WHERE event_id = p_event_id
    AND user_id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_request_not_found';
  END IF;

  IF v_row.status NOT IN ('requested', 'waitlisted') THEN
    RAISE EXCEPTION 'event_request_not_withdrawable';
  END IF;

  UPDATE public.event_rsvps
  SET status = 'cancelled',
      updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.withdraw_event_request(UUID) TO authenticated;
