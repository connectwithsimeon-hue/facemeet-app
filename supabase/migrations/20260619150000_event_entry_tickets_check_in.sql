CREATE TABLE IF NOT EXISTS public.event_tickets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  rsvp_id UUID REFERENCES public.event_rsvps(id) ON DELETE SET NULL,
  ticket_code TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'checked_in', 'void')),
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  checked_in_at TIMESTAMPTZ,
  checked_in_by UUID REFERENCES public.admin_users(id) ON DELETE SET NULL,
  voided_at TIMESTAMPTZ,
  voided_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (event_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_event_tickets_event_user
  ON public.event_tickets(event_id, user_id);

CREATE INDEX IF NOT EXISTS idx_event_tickets_code
  ON public.event_tickets(ticket_code);

CREATE INDEX IF NOT EXISTS idx_event_tickets_event_status
  ON public.event_tickets(event_id, status);

ALTER TABLE public.event_tickets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_read_own_event_tickets" ON public.event_tickets;
CREATE POLICY "users_read_own_event_tickets"
ON public.event_tickets
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "event_staff_read_event_tickets" ON public.event_tickets;
CREATE POLICY "event_staff_read_event_tickets"
ON public.event_tickets
FOR SELECT
TO authenticated
USING (
  public.has_admin_role(ARRAY['super_admin', 'events_ops', 'moderator', 'support_staff'])
);

DROP POLICY IF EXISTS "event_ops_manage_event_tickets" ON public.event_tickets;
CREATE POLICY "event_ops_manage_event_tickets"
ON public.event_tickets
FOR ALL
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'events_ops']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'events_ops']));

CREATE OR REPLACE FUNCTION public.generate_event_ticket_code()
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT;
BEGIN
  LOOP
    v_code := 'FM-' || upper(replace(gen_random_uuid()::TEXT, '-', ''));
    EXIT WHEN NOT EXISTS (
      SELECT 1
      FROM public.event_tickets et
      WHERE et.ticket_code = v_code
    );
  END LOOP;

  RETURN v_code;
END;
$$;

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
      'active',
      now(),
      NULL,
      NULL,
      now()
    )
    ON CONFLICT (event_id, user_id) DO UPDATE
      SET rsvp_id = EXCLUDED.rsvp_id,
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

DROP TRIGGER IF EXISTS trg_sync_event_ticket_from_rsvp ON public.event_rsvps;
CREATE TRIGGER trg_sync_event_ticket_from_rsvp
AFTER INSERT OR UPDATE OF status ON public.event_rsvps
FOR EACH ROW
EXECUTE FUNCTION public.sync_event_ticket_from_rsvp();

INSERT INTO public.event_tickets (
  event_id,
  user_id,
  rsvp_id,
  ticket_code,
  status,
  issued_at,
  updated_at
)
SELECT
  er.event_id,
  er.user_id,
  er.id,
  public.generate_event_ticket_code(),
  'active',
  now(),
  now()
FROM public.event_rsvps er
JOIN public.events e
  ON e.id = er.event_id
WHERE er.status = 'approved'
  AND e.status <> 'cancelled'
ON CONFLICT (event_id, user_id) DO UPDATE
  SET rsvp_id = EXCLUDED.rsvp_id,
      status = CASE
        WHEN public.event_tickets.status = 'checked_in' THEN 'checked_in'
        ELSE 'active'
      END,
      voided_at = NULL,
      voided_reason = NULL,
      updated_at = now();

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

CREATE OR REPLACE FUNCTION public.validate_event_ticket(p_ticket_code TEXT)
RETURNS TABLE (
  event_id UUID,
  event_title TEXT,
  user_id UUID,
  attendee_name TEXT,
  ticket_code TEXT,
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

  v_code := upper(BTRIM(COALESCE(p_ticket_code, '')));

  RETURN QUERY
  SELECT
    e.id,
    e.title,
    u.id,
    COALESCE(NULLIF(BTRIM(u.first_name), ''), NULLIF(BTRIM(u.username), ''), 'FaceMeet member'),
    et.ticket_code,
    et.status,
    er.status,
    e.status,
    et.checked_in_at,
    CASE
      WHEN et.id IS NULL THEN 'not_found'
      WHEN e.status = 'cancelled' THEN 'event_cancelled'
      WHEN er.status IS DISTINCT FROM 'approved' THEN 'not_active'
      WHEN et.status = 'checked_in' THEN 'already_checked_in'
      WHEN et.status <> 'active' THEN 'not_active'
      ELSE 'valid'
    END
  FROM public.event_tickets et
  JOIN public.events e
    ON e.id = et.event_id
  JOIN public.users u
    ON u.id = et.user_id
  LEFT JOIN public.event_rsvps er
    ON er.id = et.rsvp_id
  WHERE et.ticket_code = v_code;

  IF NOT FOUND THEN
    RETURN QUERY
    SELECT
      NULL::UUID,
      NULL::TEXT,
      NULL::UUID,
      NULL::TEXT,
      v_code,
      NULL::TEXT,
      NULL::TEXT,
      NULL::TEXT,
      NULL::TIMESTAMPTZ,
      'not_found'::TEXT;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_in_event_ticket(p_ticket_code TEXT)
RETURNS TABLE (
  event_id UUID,
  event_title TEXT,
  user_id UUID,
  attendee_name TEXT,
  ticket_code TEXT,
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
  v_code TEXT;
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

  v_code := upper(BTRIM(COALESCE(p_ticket_code, '')));

  SELECT *
  INTO v_ticket
  FROM public.event_tickets et
  WHERE et.ticket_code = v_code
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY
    SELECT
      NULL::UUID,
      NULL::TEXT,
      NULL::UUID,
      NULL::TEXT,
      v_code,
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
    v_ticket.status,
    v_ticket.checked_in_at,
    v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.generate_event_ticket_code() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_event_ticket_for_user(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.validate_event_ticket(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_in_event_ticket(TEXT) TO authenticated;
