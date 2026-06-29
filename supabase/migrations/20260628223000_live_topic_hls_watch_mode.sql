-- Live Topic HLS watch mode and audience/stage gate foundation.
-- Non-destructive: adds nullable HLS fields, audience access markers, and
-- server-owned Spark charges for paid viewers and approved stage speakers.

ALTER TABLE public.live_topics
  ADD COLUMN IF NOT EXISTS hls_playback_url TEXT,
  ADD COLUMN IF NOT EXISTS hls_status TEXT NOT NULL DEFAULT 'not_started',
  ADD COLUMN IF NOT EXISTS hls_started_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS hls_ended_at TIMESTAMPTZ;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'live_topics_hls_status_check'
  ) THEN
    ALTER TABLE public.live_topics
      ADD CONSTRAINT live_topics_hls_status_check
      CHECK (hls_status IN (
        'not_started',
        'pending',
        'live',
        'failed',
        'ended'
      ));
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.live_topic_viewers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  live_topic_id UUID NOT NULL REFERENCES public.live_topics(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  access_type TEXT NOT NULL,
  spark_cost INTEGER NOT NULL DEFAULT 0 CHECK (spark_cost >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT live_topic_viewers_access_type_check
    CHECK (access_type IN ('free', 'paid')),
  CONSTRAINT live_topic_viewers_unique_user
    UNIQUE (live_topic_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.live_topic_stage_charges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  live_topic_id UUID NOT NULL REFERENCES public.live_topics(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  join_request_id UUID REFERENCES public.live_topic_join_requests(id) ON DELETE SET NULL,
  spark_cost INTEGER NOT NULL DEFAULT 1 CHECK (spark_cost = 1),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT live_topic_stage_charges_unique_user
    UNIQUE (live_topic_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_live_topic_viewers_topic
  ON public.live_topic_viewers(live_topic_id);
CREATE INDEX IF NOT EXISTS idx_live_topic_viewers_user
  ON public.live_topic_viewers(user_id);
CREATE INDEX IF NOT EXISTS idx_live_topic_stage_charges_topic
  ON public.live_topic_stage_charges(live_topic_id);
CREATE INDEX IF NOT EXISTS idx_live_topic_stage_charges_user
  ON public.live_topic_stage_charges(user_id);

ALTER TABLE public.live_topic_viewers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.live_topic_stage_charges ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "live_topic_viewers_read_related" ON public.live_topic_viewers;
CREATE POLICY "live_topic_viewers_read_related"
ON public.live_topic_viewers
FOR SELECT
TO authenticated
USING (
  user_id = auth.uid()
  OR public.is_live_topic_host_or_cohost(live_topic_id, auth.uid())
);

DROP POLICY IF EXISTS "live_topic_stage_charges_read_related" ON public.live_topic_stage_charges;
CREATE POLICY "live_topic_stage_charges_read_related"
ON public.live_topic_stage_charges
FOR SELECT
TO authenticated
USING (
  user_id = auth.uid()
  OR public.is_live_topic_host_or_cohost(live_topic_id, auth.uid())
);

CREATE OR REPLACE FUNCTION public.join_live_topic_audience(
  p_live_topic_id UUID,
  p_pay BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_topic public.live_topics%ROWTYPE;
  v_existing public.live_topic_viewers%ROWTYPE;
  v_free_count INTEGER;
  v_balance INTEGER;
  v_access_type TEXT;
  v_requires_payment BOOLEAN := FALSE;
  v_granted BOOLEAN := FALSE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT *
  INTO v_topic
  FROM public.live_topics
  WHERE id = p_live_topic_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'live_topic_not_found'; END IF;
  IF v_topic.status IN ('ended', 'cancelled', 'declined') THEN
    RAISE EXCEPTION 'topic_ended';
  END IF;
  IF v_topic.status <> 'live' THEN
    RETURN jsonb_build_object(
      'success', true,
      'access_granted', false,
      'requires_payment', false,
      'status', v_topic.status,
      'free_seats_remaining', 20,
      'hls_status', v_topic.hls_status,
      'hls_playback_url', v_topic.hls_playback_url
    );
  END IF;
  IF v_uid = v_topic.creator_user_id OR v_uid = v_topic.cohost_user_id THEN
    RETURN jsonb_build_object(
      'success', true,
      'access_granted', true,
      'access_type', 'speaker',
      'requires_payment', false,
      'free_seats_remaining', 20,
      'hls_status', v_topic.hls_status,
      'hls_playback_url', v_topic.hls_playback_url
    );
  END IF;

  SELECT *
  INTO v_existing
  FROM public.live_topic_viewers
  WHERE live_topic_id = p_live_topic_id
    AND user_id = v_uid;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'access_granted', true,
      'access_type', v_existing.access_type,
      'requires_payment', false,
      'free_seats_remaining', greatest(20 - (
        SELECT count(*) FROM public.live_topic_viewers
        WHERE live_topic_id = p_live_topic_id AND access_type = 'free'
      ), 0),
      'hls_status', v_topic.hls_status,
      'hls_playback_url', v_topic.hls_playback_url
    );
  END IF;

  SELECT count(*)
  INTO v_free_count
  FROM public.live_topic_viewers
  WHERE live_topic_id = p_live_topic_id
    AND access_type = 'free';

  IF v_free_count < 20 THEN
    v_access_type := 'free';
    INSERT INTO public.live_topic_viewers(live_topic_id, user_id, access_type, spark_cost)
    VALUES (p_live_topic_id, v_uid, 'free', 0)
    ON CONFLICT (live_topic_id, user_id) DO NOTHING;
    v_granted := TRUE;
  ELSE
    IF NOT p_pay THEN
      v_requires_payment := TRUE;
    ELSE
      SELECT spark_balance
      INTO v_balance
      FROM public.users
      WHERE id = v_uid
      FOR UPDATE;

      IF coalesce(v_balance, 0) < 1 THEN
        RAISE EXCEPTION 'insufficient_sparks';
      END IF;

      INSERT INTO public.live_topic_viewers(live_topic_id, user_id, access_type, spark_cost)
      VALUES (p_live_topic_id, v_uid, 'paid', 1)
      ON CONFLICT (live_topic_id, user_id) DO NOTHING;

      IF FOUND THEN
        UPDATE public.users
        SET spark_balance = spark_balance - 1
        WHERE id = v_uid;

        INSERT INTO public.live_topic_events(
          live_topic_id,
          actor_user_id,
          event_type,
          metadata
        ) VALUES (
          p_live_topic_id,
          v_uid,
          'audience_viewer_paid',
          jsonb_build_object('spark_cost', 1)
        );
      END IF;

      v_access_type := 'paid';
      v_granted := TRUE;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'access_granted', v_granted,
    'access_type', v_access_type,
    'requires_payment', v_requires_payment,
    'free_seats_remaining', greatest(20 - v_free_count - CASE WHEN v_access_type = 'free' THEN 1 ELSE 0 END, 0),
    'hls_status', v_topic.hls_status,
    'hls_playback_url', v_topic.hls_playback_url
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.join_live_topic_stage(
  p_live_topic_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_topic public.live_topics%ROWTYPE;
  v_request public.live_topic_join_requests%ROWTYPE;
  v_charge_id UUID;
  v_balance INTEGER;
  v_stage_count INTEGER;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT *
  INTO v_topic
  FROM public.live_topics
  WHERE id = p_live_topic_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'live_topic_not_found'; END IF;
  IF v_topic.status <> 'live' THEN RAISE EXCEPTION 'topic_not_live'; END IF;
  IF v_uid = v_topic.creator_user_id OR v_uid = v_topic.cohost_user_id THEN
    RETURN jsonb_build_object('success', true, 'stage_access', true, 'role', 'host');
  END IF;

  SELECT *
  INTO v_request
  FROM public.live_topic_join_requests
  WHERE live_topic_id = p_live_topic_id
    AND requester_user_id = v_uid
    AND status = 'approved'
  ORDER BY decided_at DESC NULLS LAST, created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN RAISE EXCEPTION 'stage_request_not_approved'; END IF;

  SELECT count(*)
  INTO v_stage_count
  FROM public.live_topic_participants
  WHERE live_topic_id = p_live_topic_id
    AND role IN ('host', 'cohost', 'speaker')
    AND status IN ('accepted', 'joined');

  IF NOT EXISTS (
    SELECT 1 FROM public.live_topic_stage_charges
    WHERE live_topic_id = p_live_topic_id
      AND user_id = v_uid
  ) AND v_stage_count >= v_topic.max_speakers THEN
    RAISE EXCEPTION 'stage_full';
  END IF;

  INSERT INTO public.live_topic_stage_charges(
    live_topic_id,
    user_id,
    join_request_id,
    spark_cost
  ) VALUES (
    p_live_topic_id,
    v_uid,
    v_request.id,
    1
  )
  ON CONFLICT (live_topic_id, user_id) DO NOTHING
  RETURNING id INTO v_charge_id;

  IF v_charge_id IS NOT NULL THEN
    SELECT spark_balance
    INTO v_balance
    FROM public.users
    WHERE id = v_uid
    FOR UPDATE;

    IF coalesce(v_balance, 0) < 1 THEN
      RAISE EXCEPTION 'insufficient_sparks';
    END IF;

    UPDATE public.users
    SET spark_balance = spark_balance - 1
    WHERE id = v_uid;

    INSERT INTO public.live_topic_events(
      live_topic_id,
      actor_user_id,
      event_type,
      metadata
    ) VALUES (
      p_live_topic_id,
      v_uid,
      'stage_speaker_paid',
      jsonb_build_object('spark_cost', 1, 'request_id', v_request.id)
    );
  END IF;

  INSERT INTO public.live_topic_participants(live_topic_id, user_id, role, status, joined_at)
  VALUES (p_live_topic_id, v_uid, 'speaker', 'joined', now())
  ON CONFLICT (live_topic_id, user_id)
  DO UPDATE SET role = 'speaker', status = 'joined', joined_at = coalesce(public.live_topic_participants.joined_at, now()), updated_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'stage_access', true,
    'spark_cost', 1,
    'charged', v_charge_id IS NOT NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_live_now_topics()
RETURNS TABLE (
  id UUID,
  creator_user_id UUID,
  cohost_user_id UUID,
  title TEXT,
  topic TEXT,
  description TEXT,
  visibility TEXT,
  status TEXT,
  public_slug TEXT,
  started_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  hls_playback_url TEXT,
  hls_status TEXT,
  free_viewer_count INTEGER,
  paid_viewer_count INTEGER,
  free_seats_remaining INTEGER,
  host_profile JSONB,
  cohost_profile JSONB
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    lt.id,
    lt.creator_user_id,
    lt.cohost_user_id,
    lt.title,
    lt.topic,
    lt.description,
    lt.visibility,
    lt.status,
    lt.public_slug,
    lt.started_at,
    lt.ends_at,
    lt.hls_playback_url,
    lt.hls_status,
    coalesce(v.free_count, 0)::INTEGER AS free_viewer_count,
    coalesce(v.paid_count, 0)::INTEGER AS paid_viewer_count,
    greatest(20 - coalesce(v.free_count, 0), 0)::INTEGER AS free_seats_remaining,
    jsonb_build_object(
      'id', host.id,
      'first_name', host.first_name,
      'thumbnail_url', host.thumbnail_url
    ) AS host_profile,
    jsonb_build_object(
      'id', cohost.id,
      'first_name', cohost.first_name,
      'thumbnail_url', cohost.thumbnail_url
    ) AS cohost_profile
  FROM public.live_topics lt
  JOIN public.users host ON host.id = lt.creator_user_id
  JOIN public.users cohost ON cohost.id = lt.cohost_user_id
  LEFT JOIN LATERAL (
    SELECT
      count(*) FILTER (WHERE access_type = 'free') AS free_count,
      count(*) FILTER (WHERE access_type = 'paid') AS paid_count
    FROM public.live_topic_viewers
    WHERE live_topic_id = lt.id
  ) v ON true
  WHERE lt.status = 'live'
    AND lt.visibility IN ('public', 'link_only')
    AND coalesce(lt.ends_at, now()) > now()
  ORDER BY lt.started_at DESC NULLS LAST, lt.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.start_live_topic(p_live_topic_id UUID)
RETURNS public.live_topics
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_topic public.live_topics%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF NOT public.is_live_topic_host_or_cohost(p_live_topic_id, v_uid) THEN
    RAISE EXCEPTION 'not_host_or_cohost';
  END IF;

  UPDATE public.live_topics
  SET status = 'live',
      started_at = now(),
      ends_at = now() + interval '15 minutes',
      ended_at = NULL,
      hls_status = CASE
        WHEN hls_playback_url IS NULL OR trim(hls_playback_url) = '' THEN 'pending'
        ELSE 'live'
      END,
      hls_started_at = CASE
        WHEN hls_playback_url IS NULL OR trim(hls_playback_url) = '' THEN NULL
        ELSE now()
      END,
      hls_ended_at = NULL
  WHERE id = p_live_topic_id
    AND status = 'ready'
  RETURNING * INTO v_topic;

  IF NOT FOUND THEN RAISE EXCEPTION 'topic_not_ready'; END IF;

  INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type)
  VALUES (p_live_topic_id, v_uid, 'live_topic_started');

  RETURN v_topic;
END;
$$;

CREATE OR REPLACE FUNCTION public.end_live_topic(p_live_topic_id UUID)
RETURNS public.live_topics
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_topic public.live_topics%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF NOT public.is_live_topic_host_or_cohost(p_live_topic_id, v_uid) THEN
    RAISE EXCEPTION 'not_host_or_cohost';
  END IF;

  UPDATE public.live_topics
  SET status = 'ended',
      ended_at = now(),
      hls_status = 'ended',
      hls_ended_at = now()
  WHERE id = p_live_topic_id
    AND status IN ('ready', 'live', 'pending_cohost_acceptance')
  RETURNING * INTO v_topic;

  IF NOT FOUND THEN RAISE EXCEPTION 'topic_not_open'; END IF;

  INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type)
  VALUES (p_live_topic_id, v_uid, 'live_topic_ended');

  RETURN v_topic;
END;
$$;

CREATE OR REPLACE FUNCTION public.decide_live_topic_join_request(
  p_request_id UUID,
  p_approve BOOLEAN
) RETURNS public.live_topic_join_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_request public.live_topic_join_requests%ROWTYPE;
  v_topic public.live_topics%ROWTYPE;
  v_speaker_count INTEGER;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT * INTO v_request
  FROM public.live_topic_join_requests
  WHERE id = p_request_id
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'request_not_pending'; END IF;

  IF NOT public.is_live_topic_host_or_cohost(v_request.live_topic_id, v_uid) THEN
    RAISE EXCEPTION 'not_host_or_cohost';
  END IF;

  SELECT * INTO v_topic
  FROM public.live_topics
  WHERE id = v_request.live_topic_id;

  IF p_approve THEN
    SELECT count(*)
    INTO v_speaker_count
    FROM public.live_topic_participants
    WHERE live_topic_id = v_request.live_topic_id
      AND role IN ('host', 'cohost', 'speaker')
      AND status IN ('accepted', 'joined');

    IF v_speaker_count >= v_topic.max_speakers THEN
      RAISE EXCEPTION 'max_speakers_reached';
    END IF;

    INSERT INTO public.live_topic_participants(live_topic_id, user_id, role, status)
    VALUES (v_request.live_topic_id, v_request.requester_user_id, 'speaker', 'accepted')
    ON CONFLICT (live_topic_id, user_id)
    DO UPDATE SET role = 'speaker', status = 'accepted', updated_at = now();
  END IF;

  UPDATE public.live_topic_join_requests
  SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
      decided_at = now(),
      decided_by = v_uid
  WHERE id = p_request_id
  RETURNING * INTO v_request;

  INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type, metadata)
  VALUES (
    v_request.live_topic_id,
    v_uid,
    CASE WHEN p_approve THEN 'join_request_approved' ELSE 'join_request_rejected' END,
    jsonb_build_object('requester_user_id', v_request.requester_user_id)
  );

  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_live_topic_by_slug(p_slug TEXT)
RETURNS TABLE (
  id UUID,
  creator_user_id UUID,
  cohost_user_id UUID,
  title TEXT,
  topic TEXT,
  description TEXT,
  visibility TEXT,
  status TEXT,
  public_slug TEXT,
  started_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  ended_at TIMESTAMPTZ,
  extension_count INTEGER,
  max_speakers INTEGER,
  hls_playback_url TEXT,
  hls_status TEXT,
  hls_started_at TIMESTAMPTZ,
  hls_ended_at TIMESTAMPTZ,
  free_viewer_count INTEGER,
  paid_viewer_count INTEGER,
  free_seats_remaining INTEGER,
  viewer_access_type TEXT,
  viewer_request_status TEXT,
  viewer_stage_status TEXT,
  host_profile JSONB,
  cohost_profile JSONB,
  can_request_to_join BOOLEAN
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    lt.id,
    lt.creator_user_id,
    lt.cohost_user_id,
    lt.title,
    lt.topic,
    lt.description,
    lt.visibility,
    lt.status,
    lt.public_slug,
    lt.started_at,
    lt.ends_at,
    lt.ended_at,
    lt.extension_count,
    lt.max_speakers,
    lt.hls_playback_url,
    lt.hls_status,
    lt.hls_started_at,
    lt.hls_ended_at,
    coalesce(v.free_count, 0)::INTEGER AS free_viewer_count,
    coalesce(v.paid_count, 0)::INTEGER AS paid_viewer_count,
    greatest(20 - coalesce(v.free_count, 0), 0)::INTEGER AS free_seats_remaining,
    viewer.access_type AS viewer_access_type,
    request.status AS viewer_request_status,
    speaker.status AS viewer_stage_status,
    jsonb_build_object(
      'id', host.id,
      'first_name', host.first_name,
      'thumbnail_url', host.thumbnail_url
    ) AS host_profile,
    jsonb_build_object(
      'id', cohost.id,
      'first_name', cohost.first_name,
      'thumbnail_url', cohost.thumbnail_url
    ) AS cohost_profile,
    (
      auth.uid() IS NOT NULL
      AND lt.status = 'live'
      AND lt.visibility IN ('public', 'link_only')
      AND auth.uid() <> lt.creator_user_id
      AND auth.uid() <> lt.cohost_user_id
      AND coalesce(request.status, '') <> 'pending'
      AND coalesce(speaker.status, '') <> 'joined'
    ) AS can_request_to_join
  FROM public.live_topics lt
  JOIN public.users host ON host.id = lt.creator_user_id
  JOIN public.users cohost ON cohost.id = lt.cohost_user_id
  LEFT JOIN LATERAL (
    SELECT
      count(*) FILTER (WHERE access_type = 'free') AS free_count,
      count(*) FILTER (WHERE access_type = 'paid') AS paid_count
    FROM public.live_topic_viewers
    WHERE live_topic_id = lt.id
  ) v ON true
  LEFT JOIN public.live_topic_viewers viewer
    ON viewer.live_topic_id = lt.id
   AND viewer.user_id = auth.uid()
  LEFT JOIN LATERAL (
    SELECT r.status
    FROM public.live_topic_join_requests r
    WHERE r.live_topic_id = lt.id
      AND r.requester_user_id = auth.uid()
    ORDER BY r.created_at DESC
    LIMIT 1
  ) request ON true
  LEFT JOIN public.live_topic_participants speaker
    ON speaker.live_topic_id = lt.id
   AND speaker.user_id = auth.uid()
   AND speaker.role = 'speaker'
  WHERE lt.public_slug = p_slug
    AND (
      lt.visibility IN ('public', 'link_only')
      OR lt.creator_user_id = auth.uid()
      OR lt.cohost_user_id = auth.uid()
    );
$$;

CREATE OR REPLACE FUNCTION public.list_live_topic_join_requests(p_live_topic_id UUID)
RETURNS TABLE (
  id UUID,
  live_topic_id UUID,
  requester_user_id UUID,
  message TEXT,
  status TEXT,
  created_at TIMESTAMPTZ,
  decided_at TIMESTAMPTZ,
  decided_by UUID,
  requester_profile JSONB
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    r.id,
    r.live_topic_id,
    r.requester_user_id,
    r.message,
    r.status,
    r.created_at,
    r.decided_at,
    r.decided_by,
    jsonb_build_object(
      'id', u.id,
      'first_name', u.first_name,
      'thumbnail_url', u.thumbnail_url
    ) AS requester_profile
  FROM public.live_topic_join_requests r
  JOIN public.users u ON u.id = r.requester_user_id
  WHERE r.live_topic_id = p_live_topic_id
    AND public.is_live_topic_host_or_cohost(p_live_topic_id, auth.uid())
  ORDER BY r.created_at DESC;
$$;

REVOKE ALL ON FUNCTION public.join_live_topic_audience(UUID, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.join_live_topic_stage(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_live_now_topics() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.start_live_topic(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.end_live_topic(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.decide_live_topic_join_request(UUID, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_live_topic_by_slug(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_live_topic_join_requests(UUID) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.join_live_topic_audience(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.join_live_topic_stage(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_live_now_topics() TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_live_topic(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.end_live_topic(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.decide_live_topic_join_request(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_live_topic_by_slug(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_live_topic_join_requests(UUID) TO authenticated;
