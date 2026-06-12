-- Phase 2 events support:
--   * lightweight public events waitlist capture
--   * idempotent RSVP request helper for app/web invite requests

DROP POLICY IF EXISTS "anon_insert_waitlist_users_for_events" ON public.waitlist_users;
CREATE POLICY "anon_insert_waitlist_users_for_events"
ON public.waitlist_users
FOR INSERT
TO anon, authenticated
WITH CHECK (
  NULLIF(trim(COALESCE(email, '')), '') IS NOT NULL
  AND NULLIF(trim(COALESCE(city, '')), '') IS NOT NULL
);

CREATE OR REPLACE FUNCTION public.request_event_invite(p_event_id UUID, p_user_id UUID)
RETURNS public.event_rsvps
LANGUAGE plpgsql
AS $$
DECLARE
  v_row public.event_rsvps;
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

  INSERT INTO public.event_rsvps (event_id, user_id, status, requested_at)
  VALUES (p_event_id, p_user_id, 'requested', now())
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;
