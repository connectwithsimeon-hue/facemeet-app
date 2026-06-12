ALTER TABLE public.event_rsvps
  ADD COLUMN IF NOT EXISTS pairing_released_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.admin_release_event_pairing_results(
  p_event_id UUID
)
RETURNS TABLE (
  released_pair_count INTEGER,
  released_paired_attendee_count INTEGER,
  released_open_social_count INTEGER,
  unassigned_attendee_count INTEGER,
  draft_pair_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_now TIMESTAMPTZ := now();
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

  PERFORM pg_advisory_xact_lock(hashtextextended(p_event_id::text, 0));

  UPDATE public.event_anchor_pairs
  SET status = 'released',
      released_at = COALESCE(released_at, v_now),
      updated_at = v_now
  WHERE event_id = p_event_id
    AND status = 'confirmed';

  UPDATE public.event_rsvps er
  SET pairing_released_at = COALESCE(er.pairing_released_at, v_now),
      updated_at = v_now
  WHERE er.event_id = p_event_id
    AND er.status = 'approved'
    AND (
      er.pairing_status = 'open_social_access'
      OR (
        er.pairing_status = 'paired'
        AND EXISTS (
          SELECT 1
          FROM public.event_anchor_pairs eap
          WHERE eap.event_id = er.event_id
            AND eap.status = 'released'
            AND eap.released_at IS NOT NULL
            AND (eap.user_1_id = er.user_id OR eap.user_2_id = er.user_id)
        )
      )
    );

  PERFORM public.log_admin_action(
    'release_event_pairing_results',
    'event',
    p_event_id::text,
    jsonb_build_object('released_at', v_now)
  );

  RETURN QUERY
  SELECT
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.event_anchor_pairs eap
      WHERE eap.event_id = p_event_id
        AND eap.status = 'released'
        AND eap.released_at IS NOT NULL
    ), 0),
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.event_rsvps er
      WHERE er.event_id = p_event_id
        AND er.status = 'approved'
        AND er.pairing_status = 'paired'
        AND er.pairing_released_at IS NOT NULL
    ), 0),
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.event_rsvps er
      WHERE er.event_id = p_event_id
        AND er.status = 'approved'
        AND er.pairing_status = 'open_social_access'
        AND er.pairing_released_at IS NOT NULL
    ), 0),
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.event_rsvps er
      WHERE er.event_id = p_event_id
        AND er.status = 'approved'
        AND er.pairing_status = 'unassigned'
    ), 0),
    COALESCE((
      SELECT COUNT(*)::INTEGER
      FROM public.event_anchor_pairs eap
      WHERE eap.event_id = p_event_id
        AND eap.status = 'draft'
    ), 0);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_event_access_details()
RETURNS TABLE (
  event_id UUID,
  event_title TEXT,
  event_slug TEXT,
  starts_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  venue_name TEXT,
  venue_address TEXT,
  short_description TEXT,
  rsvp_status TEXT,
  pairing_status TEXT,
  ticket_state TEXT,
  pair_number INTEGER,
  anchor_pair_first_name TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH my_rsvps AS (
    SELECT
      er.event_id,
      er.user_id,
      e.title AS event_title,
      e.slug AS event_slug,
      e.starts_at,
      e.ends_at,
      e.venue_name,
      e.venue_address,
      e.short_description,
      er.status AS rsvp_status,
      er.pairing_status,
      er.pairing_released_at
    FROM public.event_rsvps er
    JOIN public.events e ON e.id = er.event_id
    WHERE auth.uid() IS NOT NULL
      AND er.user_id = auth.uid()
  )
  SELECT
    mr.event_id,
    mr.event_title,
    mr.event_slug,
    mr.starts_at,
    mr.ends_at,
    mr.venue_name,
    mr.venue_address,
    mr.short_description,
    mr.rsvp_status,
    mr.pairing_status,
    CASE
      WHEN mr.rsvp_status <> 'approved' THEN 'not_approved'
      WHEN mr.pairing_status = 'unassigned' THEN 'approved_unassigned'
      WHEN mr.pairing_status = 'open_social_access' AND mr.pairing_released_at IS NOT NULL THEN 'released_open_social_access'
      WHEN mr.pairing_status = 'paired' AND released_pair.pair_number IS NOT NULL AND mr.pairing_released_at IS NOT NULL THEN 'released_anchor_pair'
      WHEN mr.pairing_released_at IS NULL THEN 'approved_unreleased'
      ELSE 'approved_unreleased'
    END AS ticket_state,
    CASE
      WHEN mr.rsvp_status = 'approved'
        AND mr.pairing_status = 'paired'
        AND mr.pairing_released_at IS NOT NULL
        AND released_pair.pair_number IS NOT NULL
      THEN released_pair.pair_number
      ELSE NULL
    END AS pair_number,
    CASE
      WHEN mr.rsvp_status = 'approved'
        AND mr.pairing_status = 'paired'
        AND mr.pairing_released_at IS NOT NULL
        AND released_pair.pair_number IS NOT NULL
      THEN anchor_user.first_name
      ELSE NULL
    END AS anchor_pair_first_name
  FROM my_rsvps mr
  LEFT JOIN LATERAL (
    SELECT
      eap.pair_number,
      CASE
        WHEN eap.user_1_id = mr.user_id THEN eap.user_2_id
        ELSE eap.user_1_id
      END AS anchor_pair_user_id
    FROM public.event_anchor_pairs eap
    WHERE eap.event_id = mr.event_id
      AND eap.status = 'released'
      AND eap.released_at IS NOT NULL
      AND (eap.user_1_id = mr.user_id OR eap.user_2_id = mr.user_id)
    ORDER BY eap.released_at DESC, eap.pair_number DESC
    LIMIT 1
  ) AS released_pair ON mr.pairing_status = 'paired'
  LEFT JOIN public.users anchor_user ON anchor_user.id = released_pair.anchor_pair_user_id
  ORDER BY mr.starts_at ASC;
$$;

GRANT EXECUTE ON FUNCTION public.admin_release_event_pairing_results(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_event_access_details() TO authenticated;
