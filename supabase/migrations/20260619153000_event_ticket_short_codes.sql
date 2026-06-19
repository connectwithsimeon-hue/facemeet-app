ALTER TABLE public.event_tickets
  ADD COLUMN IF NOT EXISTS short_code TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_event_tickets_short_code
  ON public.event_tickets(short_code)
  WHERE short_code IS NOT NULL;

CREATE OR REPLACE FUNCTION public.normalize_event_ticket_lookup_code(p_code TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT regexp_replace(upper(BTRIM(COALESCE(p_code, ''))), '[^A-Z0-9]', '', 'g');
$$;

CREATE OR REPLACE FUNCTION public.generate_event_ticket_short_code()
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_alphabet CONSTANT TEXT := 'ABCDEFGHJKMNPQRTUVWXY346789';
  v_raw TEXT;
  v_code TEXT;
  v_index INTEGER;
BEGIN
  LOOP
    v_raw := '';
    FOR i IN 1..6 LOOP
      v_index := 1 + floor(random() * length(v_alphabet))::INTEGER;
      v_raw := v_raw || substr(v_alphabet, v_index, 1);
    END LOOP;

    v_code := 'FM-' || substr(v_raw, 1, 3) || '-' || substr(v_raw, 4, 3);

    EXIT WHEN NOT EXISTS (
      SELECT 1
      FROM public.event_tickets et
      WHERE et.short_code = v_code
    );
  END LOOP;

  RETURN v_code;
END;
$$;

UPDATE public.event_tickets et
SET short_code = public.generate_event_ticket_short_code(),
    updated_at = now()
WHERE et.short_code IS NULL;

ALTER TABLE public.event_tickets
  ALTER COLUMN short_code SET NOT NULL;

CREATE OR REPLACE FUNCTION public.sync_event_ticket_from_rsvp()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_status TEXT;
BEGIN
  SELECT e.status
  INTO v_event_status
  FROM public.events e
  WHERE e.id = NEW.event_id;

  IF NEW.status = 'approved' AND COALESCE(v_event_status, '') <> 'cancelled' THEN
    INSERT INTO public.event_tickets (
      event_id,
      user_id,
      rsvp_id,
      ticket_code,
      short_code,
      status,
      issued_at,
      voided_at,
      voided_reason,
      updated_at
    )
    VALUES (
      NEW.event_id,
      NEW.user_id,
      NEW.id,
      public.generate_event_ticket_code(),
      public.generate_event_ticket_short_code(),
      'active',
      now(),
      NULL,
      NULL,
      now()
    )
    ON CONFLICT (event_id, user_id) DO UPDATE
      SET rsvp_id = EXCLUDED.rsvp_id,
          short_code = COALESCE(public.event_tickets.short_code, public.generate_event_ticket_short_code()),
          status = CASE
            WHEN public.event_tickets.status = 'checked_in' THEN 'checked_in'
            ELSE 'active'
          END,
          issued_at = CASE
            WHEN public.event_tickets.status = 'checked_in' THEN public.event_tickets.issued_at
            ELSE now()
          END,
          voided_at = NULL,
          voided_reason = NULL,
          updated_at = now();
  ELSE
    UPDATE public.event_tickets
    SET status = CASE
          WHEN status = 'checked_in' THEN status
          ELSE 'void'
        END,
        voided_at = CASE
          WHEN status = 'checked_in' THEN voided_at
          ELSE now()
        END,
        voided_reason = CASE
          WHEN status = 'checked_in' THEN voided_reason
          WHEN COALESCE(v_event_status, '') = 'cancelled' THEN 'event_cancelled'
          ELSE 'rsvp_not_approved'
        END,
        updated_at = now()
    WHERE event_id = NEW.event_id
      AND user_id = NEW.user_id
      AND status <> 'checked_in';
  END IF;

  RETURN NEW;
END;
$$;

DROP FUNCTION IF EXISTS public.get_event_ticket_for_user(UUID);

CREATE OR REPLACE FUNCTION public.get_event_ticket_for_user(p_event_id UUID)
RETURNS TABLE (
  event_id UUID,
  event_title TEXT,
  user_id UUID,
  rsvp_id UUID,
  ticket_code TEXT,
  short_code TEXT,
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
    short_code,
    status,
    issued_at,
    updated_at
  )
  VALUES (
    p_event_id,
    v_user_id,
    v_rsvp.id,
    public.generate_event_ticket_code(),
    public.generate_event_ticket_short_code(),
    'active',
    now(),
    now()
  )
  ON CONFLICT ON CONSTRAINT event_tickets_event_id_user_id_key DO UPDATE
    SET rsvp_id = EXCLUDED.rsvp_id,
        short_code = COALESCE(public.event_tickets.short_code, public.generate_event_ticket_short_code()),
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
    v_ticket.short_code,
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

CREATE OR REPLACE FUNCTION public.find_event_ticket_by_code(p_ticket_code TEXT)
RETURNS SETOF public.event_tickets
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH lookup AS (
    SELECT
      public.normalize_event_ticket_lookup_code(p_ticket_code) AS compact_code,
      regexp_replace(upper(BTRIM(COALESCE(p_ticket_code, ''))), '[^A-Z0-9]', '', 'g') AS raw_compact
  )
  SELECT et.*
  FROM public.event_tickets et
  CROSS JOIN lookup l
  WHERE public.normalize_event_ticket_lookup_code(et.short_code) = CASE
      WHEN left(l.compact_code, 2) = 'FM' THEN l.compact_code
      ELSE 'FM' || l.compact_code
    END
    OR public.normalize_event_ticket_lookup_code(et.ticket_code) = l.raw_compact
    OR replace(public.normalize_event_ticket_lookup_code(et.ticket_code), '0', 'O') = l.raw_compact
  LIMIT 1;
$$;

DROP FUNCTION IF EXISTS public.validate_event_ticket(TEXT);

CREATE OR REPLACE FUNCTION public.validate_event_ticket(p_ticket_code TEXT)
RETURNS TABLE (
  event_id UUID,
  event_title TEXT,
  user_id UUID,
  attendee_name TEXT,
  ticket_code TEXT,
  short_code TEXT,
  ticket_status TEXT,
  rsvp_status TEXT,
  event_status TEXT,
  checked_in_at TIMESTAMPTZ,
  result TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_code TEXT;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'events_ops', 'moderator', 'support_staff']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  v_code := public.normalize_event_ticket_lookup_code(p_ticket_code);

  RETURN QUERY
  SELECT
    e.id,
    e.title,
    u.id,
    COALESCE(NULLIF(BTRIM(u.first_name), ''), NULLIF(BTRIM(u.username), ''), 'FaceMeet member'),
    et.ticket_code,
    et.short_code,
    et.status,
    er.status,
    e.status,
    et.checked_in_at,
    CASE
      WHEN e.status = 'cancelled' THEN 'event_cancelled'
      WHEN er.status IS DISTINCT FROM 'approved' THEN 'not_active'
      WHEN et.status = 'checked_in' THEN 'already_checked_in'
      WHEN et.status <> 'active' THEN 'not_active'
      ELSE 'valid'
    END
  FROM public.find_event_ticket_by_code(p_ticket_code) et
  JOIN public.events e
    ON e.id = et.event_id
  JOIN public.users u
    ON u.id = et.user_id
  LEFT JOIN public.event_rsvps er
    ON er.id = et.rsvp_id;

  IF NOT FOUND THEN
    RETURN QUERY
    SELECT
      NULL::UUID,
      NULL::TEXT,
      NULL::UUID,
      NULL::TEXT,
      NULL::TEXT,
      NULL::TEXT,
      NULL::TEXT,
      NULL::TEXT,
      NULL::TEXT,
      NULL::TIMESTAMPTZ,
      'not_found'::TEXT;
  END IF;
END;
$$;

DROP FUNCTION IF EXISTS public.check_in_event_ticket(TEXT);

CREATE OR REPLACE FUNCTION public.check_in_event_ticket(p_ticket_code TEXT)
RETURNS TABLE (
  event_id UUID,
  event_title TEXT,
  user_id UUID,
  attendee_name TEXT,
  ticket_code TEXT,
  short_code TEXT,
  ticket_status TEXT,
  checked_in_at TIMESTAMPTZ,
  result TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_ticket public.event_tickets%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_rsvp_status TEXT;
  v_attendee_name TEXT;
  v_result TEXT;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'events_ops', 'moderator', 'support_staff']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  SELECT *
  INTO v_ticket
  FROM public.event_tickets et
  WHERE et.id = (
    SELECT found.id
    FROM public.find_event_ticket_by_code(p_ticket_code) found
    LIMIT 1
  )
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY
    SELECT
      NULL::UUID,
      NULL::TEXT,
      NULL::UUID,
      NULL::TEXT,
      NULL::TEXT,
      NULL::TEXT,
      NULL::TEXT,
      NULL::TIMESTAMPTZ,
      'not_found'::TEXT;
    RETURN;
  END IF;

  SELECT *
  INTO v_event
  FROM public.events e
  WHERE e.id = v_ticket.event_id;

  SELECT er.status
  INTO v_rsvp_status
  FROM public.event_rsvps er
  WHERE er.id = v_ticket.rsvp_id;

  SELECT COALESCE(NULLIF(BTRIM(u.first_name), ''), NULLIF(BTRIM(u.username), ''), 'FaceMeet member')
  INTO v_attendee_name
  FROM public.users u
  WHERE u.id = v_ticket.user_id;

  IF v_event.status = 'cancelled' THEN
    v_result := 'event_cancelled';
  ELSIF v_rsvp_status IS DISTINCT FROM 'approved' OR v_ticket.status = 'void' THEN
    v_result := 'not_active';
  ELSIF v_ticket.status = 'checked_in' THEN
    v_result := 'already_checked_in';
  ELSE
    UPDATE public.event_tickets
    SET status = 'checked_in',
        checked_in_at = now(),
        checked_in_by = v_admin_user_id,
        updated_at = now()
    WHERE id = v_ticket.id
    RETURNING * INTO v_ticket;
    v_result := 'checked_in';
  END IF;

  IF v_result IN ('checked_in', 'already_checked_in') THEN
    PERFORM public.log_admin_action(
      'event_ticket_check_in',
      'event_ticket',
      v_ticket.id::TEXT,
      jsonb_build_object(
        'event_id', v_ticket.event_id,
        'user_id', v_ticket.user_id,
        'result', v_result
      )
    );
  END IF;

  RETURN QUERY
  SELECT
    v_event.id,
    v_event.title,
    v_ticket.user_id,
    COALESCE(v_attendee_name, 'FaceMeet member'),
    v_ticket.ticket_code,
    v_ticket.short_code,
    v_ticket.status,
    v_ticket.checked_in_at,
    v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.normalize_event_ticket_lookup_code(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_event_ticket_short_code() TO authenticated;
GRANT EXECUTE ON FUNCTION public.find_event_ticket_by_code(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_event_ticket_for_user(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.validate_event_ticket(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_in_event_ticket(TEXT) TO authenticated;
