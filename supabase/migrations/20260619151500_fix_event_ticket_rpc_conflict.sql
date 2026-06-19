CREATE OR REPLACE FUNCTION public.get_event_ticket_for_user(p_event_id UUID)
RETURNS TABLE (
  event_id UUID,
  event_title TEXT,
  user_id UUID,
  rsvp_id UUID,
  ticket_code TEXT,
  ticket_status TEXT,
  issued_at TIMESTAMPTZ,
  checked_in_at TIMESTAMPTZ,
  attendee_name TEXT,
  ticket_available BOOLEAN,
  message TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_event public.events%ROWTYPE;
  v_rsvp public.event_rsvps%ROWTYPE;
  v_ticket public.event_tickets%ROWTYPE;
  v_attendee_name TEXT;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  SELECT *
  INTO v_event
  FROM public.events e
  WHERE e.id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found';
  END IF;

  SELECT *
  INTO v_rsvp
  FROM public.event_rsvps er
  WHERE er.event_id = p_event_id
    AND er.user_id = v_user_id
  LIMIT 1;

  SELECT COALESCE(NULLIF(BTRIM(u.first_name), ''), NULLIF(BTRIM(u.username), ''), 'FaceMeet member')
  INTO v_attendee_name
  FROM public.users u
  WHERE u.id = v_user_id;

  IF NOT FOUND OR v_rsvp.status <> 'approved' OR v_event.status = 'cancelled' THEN
    UPDATE public.event_tickets et
    SET status = CASE
          WHEN et.status = 'checked_in' THEN et.status
          ELSE 'void'
        END,
        voided_at = CASE
          WHEN et.status = 'checked_in' THEN et.voided_at
          ELSE now()
        END,
        voided_reason = CASE
          WHEN et.status = 'checked_in' THEN et.voided_reason
          WHEN v_event.status = 'cancelled' THEN 'event_cancelled'
          ELSE 'rsvp_not_approved'
        END,
        updated_at = now()
    WHERE et.event_id = p_event_id
      AND et.user_id = v_user_id
      AND et.status <> 'checked_in';

    RETURN QUERY
    SELECT
      v_event.id,
      v_event.title,
      v_user_id,
      NULL::UUID,
      NULL::TEXT,
      'unavailable'::TEXT,
      NULL::TIMESTAMPTZ,
      NULL::TIMESTAMPTZ,
      COALESCE(v_attendee_name, 'FaceMeet member'),
      FALSE,
      CASE
        WHEN v_event.status = 'cancelled' THEN 'event_cancelled'
        ELSE 'approval_required'
      END;
    RETURN;
  END IF;

  INSERT INTO public.event_tickets (
    event_id,
    user_id,
    rsvp_id,
    ticket_code,
    status,
    issued_at,
    updated_at
  )
  VALUES (
    p_event_id,
    v_user_id,
    v_rsvp.id,
    public.generate_event_ticket_code(),
    'active',
    now(),
    now()
  )
  ON CONFLICT ON CONSTRAINT event_tickets_event_id_user_id_key DO UPDATE
    SET rsvp_id = EXCLUDED.rsvp_id,
        status = CASE
          WHEN public.event_tickets.status = 'checked_in' THEN 'checked_in'
          ELSE 'active'
        END,
        voided_at = NULL,
        voided_reason = NULL,
        updated_at = now()
  RETURNING * INTO v_ticket;

  RETURN QUERY
  SELECT
    v_event.id,
    v_event.title,
    v_user_id,
    v_ticket.rsvp_id,
    v_ticket.ticket_code,
    v_ticket.status,
    v_ticket.issued_at,
    v_ticket.checked_in_at,
    COALESCE(v_attendee_name, 'FaceMeet member'),
    v_ticket.status IN ('active', 'checked_in'),
    CASE
      WHEN v_ticket.status = 'checked_in' THEN 'checked_in'
      ELSE 'active'
    END;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_event_ticket_for_user(UUID) TO authenticated;
