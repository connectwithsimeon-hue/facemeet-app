-- Live Topics MVP foundation
-- Public/link-shareable 15-minute topic conversations between connected users.

CREATE TABLE IF NOT EXISTS public.live_topics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  cohost_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  topic TEXT NOT NULL,
  description TEXT,
  visibility TEXT NOT NULL DEFAULT 'link_only',
  status TEXT NOT NULL DEFAULT 'pending_cohost_acceptance',
  spark_cost INTEGER NOT NULL DEFAULT 1 CHECK (spark_cost >= 0),
  duration_minutes INTEGER NOT NULL DEFAULT 15 CHECK (duration_minutes > 0),
  extension_count INTEGER NOT NULL DEFAULT 0 CHECK (extension_count >= 0),
  max_speakers INTEGER NOT NULL DEFAULT 4 CHECK (max_speakers >= 2),
  public_slug TEXT UNIQUE,
  daily_room_url TEXT,
  daily_room_name TEXT,
  started_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  ended_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT live_topics_visibility_check
    CHECK (visibility IN ('public', 'link_only', 'invite_only')),
  CONSTRAINT live_topics_status_check
    CHECK (status IN (
      'pending_cohost_acceptance',
      'ready',
      'live',
      'ended',
      'cancelled',
      'declined'
    )),
  CONSTRAINT live_topics_hosts_distinct_check
    CHECK (creator_user_id <> cohost_user_id)
);

CREATE TABLE IF NOT EXISTS public.live_topic_participants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  live_topic_id UUID NOT NULL REFERENCES public.live_topics(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'invited',
  joined_at TIMESTAMPTZ,
  left_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT live_topic_participants_role_check
    CHECK (role IN ('host', 'cohost', 'speaker', 'viewer')),
  CONSTRAINT live_topic_participants_status_check
    CHECK (status IN ('invited', 'accepted', 'declined', 'joined', 'left', 'removed')),
  CONSTRAINT live_topic_participants_unique_user
    UNIQUE (live_topic_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.live_topic_join_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  live_topic_id UUID NOT NULL REFERENCES public.live_topics(id) ON DELETE CASCADE,
  requester_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  message TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at TIMESTAMPTZ,
  decided_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
  CONSTRAINT live_topic_join_requests_status_check
    CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled'))
);

CREATE TABLE IF NOT EXISTS public.live_topic_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  live_topic_id UUID NOT NULL REFERENCES public.live_topics(id) ON DELETE CASCADE,
  actor_user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_live_topic_join_requests_one_pending
  ON public.live_topic_join_requests(live_topic_id, requester_user_id)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_live_topics_creator ON public.live_topics(creator_user_id);
CREATE INDEX IF NOT EXISTS idx_live_topics_cohost ON public.live_topics(cohost_user_id);
CREATE INDEX IF NOT EXISTS idx_live_topics_status ON public.live_topics(status);
CREATE INDEX IF NOT EXISTS idx_live_topics_slug ON public.live_topics(public_slug);
CREATE INDEX IF NOT EXISTS idx_live_topic_participants_topic ON public.live_topic_participants(live_topic_id);
CREATE INDEX IF NOT EXISTS idx_live_topic_participants_user ON public.live_topic_participants(user_id);
CREATE INDEX IF NOT EXISTS idx_live_topic_join_requests_topic ON public.live_topic_join_requests(live_topic_id);

ALTER TABLE public.live_topics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.live_topic_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.live_topic_join_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.live_topic_events ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_live_topic_host_or_cohost(
  p_live_topic_id UUID,
  p_user_id UUID
) RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.live_topics lt
    WHERE lt.id = p_live_topic_id
      AND (lt.creator_user_id = p_user_id OR lt.cohost_user_id = p_user_id)
  );
$$;

DROP POLICY IF EXISTS "live_topics_read_safe" ON public.live_topics;
CREATE POLICY "live_topics_read_safe"
ON public.live_topics
FOR SELECT
TO authenticated
USING (
  visibility IN ('public', 'link_only')
  OR creator_user_id = auth.uid()
  OR cohost_user_id = auth.uid()
);

DROP POLICY IF EXISTS "live_topics_insert_self" ON public.live_topics;
CREATE POLICY "live_topics_insert_self"
ON public.live_topics
FOR INSERT
TO authenticated
WITH CHECK (creator_user_id = auth.uid());

DROP POLICY IF EXISTS "live_topics_update_hosts" ON public.live_topics;
CREATE POLICY "live_topics_update_hosts"
ON public.live_topics
FOR UPDATE
TO authenticated
USING (creator_user_id = auth.uid() OR cohost_user_id = auth.uid())
WITH CHECK (creator_user_id = auth.uid() OR cohost_user_id = auth.uid());

DROP POLICY IF EXISTS "live_topic_participants_read_related" ON public.live_topic_participants;
CREATE POLICY "live_topic_participants_read_related"
ON public.live_topic_participants
FOR SELECT
TO authenticated
USING (
  user_id = auth.uid()
  OR public.is_live_topic_host_or_cohost(live_topic_id, auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.live_topics lt
    WHERE lt.id = live_topic_id
      AND lt.visibility IN ('public', 'link_only')
  )
);

DROP POLICY IF EXISTS "live_topic_participants_insert_self_or_host" ON public.live_topic_participants;
CREATE POLICY "live_topic_participants_insert_self_or_host"
ON public.live_topic_participants
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = auth.uid()
  OR public.is_live_topic_host_or_cohost(live_topic_id, auth.uid())
);

DROP POLICY IF EXISTS "live_topic_participants_update_self_or_host" ON public.live_topic_participants;
CREATE POLICY "live_topic_participants_update_self_or_host"
ON public.live_topic_participants
FOR UPDATE
TO authenticated
USING (
  user_id = auth.uid()
  OR public.is_live_topic_host_or_cohost(live_topic_id, auth.uid())
)
WITH CHECK (
  user_id = auth.uid()
  OR public.is_live_topic_host_or_cohost(live_topic_id, auth.uid())
);

DROP POLICY IF EXISTS "live_topic_join_requests_read_related" ON public.live_topic_join_requests;
CREATE POLICY "live_topic_join_requests_read_related"
ON public.live_topic_join_requests
FOR SELECT
TO authenticated
USING (
  requester_user_id = auth.uid()
  OR public.is_live_topic_host_or_cohost(live_topic_id, auth.uid())
);

DROP POLICY IF EXISTS "live_topic_join_requests_insert_self" ON public.live_topic_join_requests;
CREATE POLICY "live_topic_join_requests_insert_self"
ON public.live_topic_join_requests
FOR INSERT
TO authenticated
WITH CHECK (requester_user_id = auth.uid());

DROP POLICY IF EXISTS "live_topic_join_requests_update_host" ON public.live_topic_join_requests;
CREATE POLICY "live_topic_join_requests_update_host"
ON public.live_topic_join_requests
FOR UPDATE
TO authenticated
USING (public.is_live_topic_host_or_cohost(live_topic_id, auth.uid()))
WITH CHECK (public.is_live_topic_host_or_cohost(live_topic_id, auth.uid()));

DROP POLICY IF EXISTS "live_topic_events_read_related" ON public.live_topic_events;
CREATE POLICY "live_topic_events_read_related"
ON public.live_topic_events
FOR SELECT
TO authenticated
USING (
  public.is_live_topic_host_or_cohost(live_topic_id, auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.live_topics lt
    WHERE lt.id = live_topic_id
      AND lt.visibility IN ('public', 'link_only')
  )
);

CREATE OR REPLACE FUNCTION public.touch_live_topic_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_live_topics_updated_at ON public.live_topics;
CREATE TRIGGER trg_touch_live_topics_updated_at
BEFORE UPDATE ON public.live_topics
FOR EACH ROW
EXECUTE FUNCTION public.touch_live_topic_updated_at();

DROP TRIGGER IF EXISTS trg_touch_live_topic_participants_updated_at ON public.live_topic_participants;
CREATE TRIGGER trg_touch_live_topic_participants_updated_at
BEFORE UPDATE ON public.live_topic_participants
FOR EACH ROW
EXECUTE FUNCTION public.touch_live_topic_updated_at();

CREATE OR REPLACE FUNCTION public.generate_live_topic_slug(p_title TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_base TEXT;
  v_slug TEXT;
BEGIN
  v_base := regexp_replace(lower(coalesce(p_title, 'live-topic')), '[^a-z0-9]+', '-', 'g');
  v_base := trim(both '-' from v_base);
  IF v_base = '' THEN
    v_base := 'live-topic';
  END IF;

  LOOP
    v_slug := left(v_base, 36) || '-' || lower(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 6));
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM public.live_topics WHERE public_slug = v_slug
    );
  END LOOP;

  RETURN v_slug;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_live_topic_from_connection(
  p_cohost_user_id UUID,
  p_title TEXT,
  p_topic TEXT,
  p_description TEXT DEFAULT NULL,
  p_visibility TEXT DEFAULT 'link_only'
) RETURNS public.live_topics
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_topic public.live_topics%ROWTYPE;
  v_has_connection BOOLEAN;
  v_balance INTEGER;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;
  IF p_cohost_user_id IS NULL OR p_cohost_user_id = v_uid THEN
    RAISE EXCEPTION 'invalid_cohost';
  END IF;
  IF length(trim(coalesce(p_title, ''))) < 3 THEN
    RAISE EXCEPTION 'title_required';
  END IF;
  IF length(trim(coalesce(p_topic, ''))) < 3 THEN
    RAISE EXCEPTION 'topic_required';
  END IF;
  IF coalesce(p_visibility, 'link_only') NOT IN ('public', 'link_only', 'invite_only') THEN
    RAISE EXCEPTION 'invalid_visibility';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.matches m
    WHERE m.status = 'chat_unlocked'
      AND (
        (m.user_1_id = v_uid AND m.user_2_id = p_cohost_user_id)
        OR (m.user_2_id = v_uid AND m.user_1_id = p_cohost_user_id)
      )
  ) INTO v_has_connection;

  IF NOT v_has_connection THEN
    RAISE EXCEPTION 'connection_required';
  END IF;

  SELECT spark_balance
  INTO v_balance
  FROM public.users
  WHERE id = v_uid
  FOR UPDATE;

  IF coalesce(v_balance, 0) < 1 THEN
    RAISE EXCEPTION 'not_enough_sparks';
  END IF;

  UPDATE public.users
  SET spark_balance = spark_balance - 1
  WHERE id = v_uid;

  INSERT INTO public.live_topics (
    creator_user_id,
    cohost_user_id,
    title,
    topic,
    description,
    visibility,
    status,
    public_slug
  ) VALUES (
    v_uid,
    p_cohost_user_id,
    trim(p_title),
    trim(p_topic),
    nullif(trim(coalesce(p_description, '')), ''),
    coalesce(p_visibility, 'link_only'),
    'pending_cohost_acceptance',
    public.generate_live_topic_slug(p_title)
  )
  RETURNING * INTO v_topic;

  INSERT INTO public.live_topic_participants(live_topic_id, user_id, role, status, joined_at)
  VALUES
    (v_topic.id, v_uid, 'host', 'accepted', now()),
    (v_topic.id, p_cohost_user_id, 'cohost', 'invited', NULL);

  INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type, metadata)
  VALUES (
    v_topic.id,
    v_uid,
    'live_topic_created',
    jsonb_build_object('spark_cost', 1, 'visibility', v_topic.visibility)
  );

  RETURN v_topic;
END;
$$;

CREATE OR REPLACE FUNCTION public.respond_live_topic_cohost_invite(
  p_live_topic_id UUID,
  p_accept BOOLEAN
) RETURNS public.live_topics
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_topic public.live_topics%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT *
  INTO v_topic
  FROM public.live_topics
  WHERE id = p_live_topic_id
    AND cohost_user_id = v_uid
    AND status = 'pending_cohost_acceptance'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invite_not_available';
  END IF;

  IF p_accept THEN
    UPDATE public.live_topic_participants
    SET status = 'accepted', updated_at = now()
    WHERE live_topic_id = p_live_topic_id
      AND user_id = v_uid
      AND role = 'cohost';

    UPDATE public.live_topics
    SET status = 'ready'
    WHERE id = p_live_topic_id
    RETURNING * INTO v_topic;

    INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type)
    VALUES (p_live_topic_id, v_uid, 'cohost_accepted');
  ELSE
    UPDATE public.live_topic_participants
    SET status = 'declined', updated_at = now()
    WHERE live_topic_id = p_live_topic_id
      AND user_id = v_uid
      AND role = 'cohost';

    UPDATE public.live_topics
    SET status = 'declined', ended_at = now()
    WHERE id = p_live_topic_id
    RETURNING * INTO v_topic;

    INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type)
    VALUES (p_live_topic_id, v_uid, 'cohost_declined');
  END IF;

  RETURN v_topic;
END;
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
      ended_at = NULL
  WHERE id = p_live_topic_id
    AND status = 'ready'
  RETURNING * INTO v_topic;

  IF NOT FOUND THEN RAISE EXCEPTION 'topic_not_ready'; END IF;

  INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type)
  VALUES (p_live_topic_id, v_uid, 'live_topic_started');

  RETURN v_topic;
END;
$$;

CREATE OR REPLACE FUNCTION public.extend_live_topic(p_live_topic_id UUID)
RETURNS public.live_topics
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_topic public.live_topics%ROWTYPE;
  v_balance INTEGER;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF NOT public.is_live_topic_host_or_cohost(p_live_topic_id, v_uid) THEN
    RAISE EXCEPTION 'not_host_or_cohost';
  END IF;

  SELECT spark_balance
  INTO v_balance
  FROM public.users
  WHERE id = v_uid
  FOR UPDATE;

  IF coalesce(v_balance, 0) < 1 THEN
    RAISE EXCEPTION 'not_enough_sparks';
  END IF;

  UPDATE public.users
  SET spark_balance = spark_balance - 1
  WHERE id = v_uid;

  UPDATE public.live_topics
  SET ends_at = greatest(coalesce(ends_at, now()), now()) + interval '15 minutes',
      extension_count = extension_count + 1
  WHERE id = p_live_topic_id
    AND status = 'live'
  RETURNING * INTO v_topic;

  IF NOT FOUND THEN RAISE EXCEPTION 'topic_not_live'; END IF;

  INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type, metadata)
  VALUES (p_live_topic_id, v_uid, 'live_topic_extended', jsonb_build_object('spark_cost', 1));

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
      ended_at = now()
  WHERE id = p_live_topic_id
    AND status IN ('ready', 'live', 'pending_cohost_acceptance')
  RETURNING * INTO v_topic;

  IF NOT FOUND THEN RAISE EXCEPTION 'topic_not_open'; END IF;

  INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type)
  VALUES (p_live_topic_id, v_uid, 'live_topic_ended');

  RETURN v_topic;
END;
$$;

CREATE OR REPLACE FUNCTION public.request_to_join_live_topic(
  p_live_topic_id UUID,
  p_message TEXT DEFAULT NULL
) RETURNS public.live_topic_join_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_request public.live_topic_join_requests%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF public.is_live_topic_host_or_cohost(p_live_topic_id, v_uid) THEN
    RAISE EXCEPTION 'hosts_cannot_request';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.live_topics
    WHERE id = p_live_topic_id
      AND status = 'live'
      AND visibility IN ('public', 'link_only')
  ) THEN
    RAISE EXCEPTION 'topic_not_joinable';
  END IF;

  INSERT INTO public.live_topic_join_requests(live_topic_id, requester_user_id, message, status)
  VALUES (p_live_topic_id, v_uid, nullif(trim(coalesce(p_message, '')), ''), 'pending')
  ON CONFLICT (live_topic_id, requester_user_id) WHERE status = 'pending'
  DO UPDATE SET message = EXCLUDED.message, created_at = now()
  RETURNING * INTO v_request;

  INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type)
  VALUES (p_live_topic_id, v_uid, 'join_requested');

  RETURN v_request;
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
      AND NOT EXISTS (
        SELECT 1 FROM public.live_topic_join_requests r
        WHERE r.live_topic_id = lt.id
          AND r.requester_user_id = auth.uid()
          AND r.status = 'pending'
      )
    ) AS can_request_to_join
  FROM public.live_topics lt
  JOIN public.users host ON host.id = lt.creator_user_id
  JOIN public.users cohost ON cohost.id = lt.cohost_user_id
  WHERE lt.public_slug = p_slug
    AND (
      lt.visibility IN ('public', 'link_only')
      OR lt.creator_user_id = auth.uid()
      OR lt.cohost_user_id = auth.uid()
    );
$$;

CREATE OR REPLACE FUNCTION public.list_my_live_topics()
RETURNS SETOF public.live_topics
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT lt.*
  FROM public.live_topics lt
  WHERE lt.creator_user_id = auth.uid()
     OR lt.cohost_user_id = auth.uid()
  ORDER BY lt.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.list_live_topic_join_requests(p_live_topic_id UUID)
RETURNS SETOF public.live_topic_join_requests
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT r.*
  FROM public.live_topic_join_requests r
  WHERE r.live_topic_id = p_live_topic_id
    AND public.is_live_topic_host_or_cohost(p_live_topic_id, auth.uid())
  ORDER BY r.created_at ASC;
$$;
