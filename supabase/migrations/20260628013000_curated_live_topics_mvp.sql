-- Curated Live Topics MVP
-- Normal users select active FaceMeet-curated topics instead of typing custom topics.

CREATE TABLE IF NOT EXISTS public.curated_live_topics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  category TEXT NOT NULL,
  prompt TEXT NOT NULL,
  description TEXT,
  share_hook TEXT,
  source_summary TEXT,
  status TEXT NOT NULL DEFAULT 'draft',
  featured BOOLEAN NOT NULL DEFAULT false,
  starts_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
  created_by_ai BOOLEAN NOT NULL DEFAULT false,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT curated_live_topics_status_check
    CHECK (status IN ('draft', 'active', 'archived', 'rejected')),
  CONSTRAINT curated_live_topics_title_key UNIQUE (title)
);

ALTER TABLE public.live_topics
  ADD COLUMN IF NOT EXISTS curated_topic_id UUID REFERENCES public.curated_live_topics(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_curated_live_topics_status
  ON public.curated_live_topics(status);
CREATE INDEX IF NOT EXISTS idx_curated_live_topics_category
  ON public.curated_live_topics(category);
CREATE INDEX IF NOT EXISTS idx_curated_live_topics_featured
  ON public.curated_live_topics(featured);
CREATE INDEX IF NOT EXISTS idx_curated_live_topics_starts_at
  ON public.curated_live_topics(starts_at);
CREATE INDEX IF NOT EXISTS idx_curated_live_topics_expires_at
  ON public.curated_live_topics(expires_at);
CREATE INDEX IF NOT EXISTS idx_curated_live_topics_sort_order
  ON public.curated_live_topics(sort_order);
CREATE INDEX IF NOT EXISTS idx_live_topics_curated_topic
  ON public.live_topics(curated_topic_id);

CREATE OR REPLACE FUNCTION public.touch_curated_live_topics_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_curated_live_topics_updated_at ON public.curated_live_topics;
CREATE TRIGGER trg_touch_curated_live_topics_updated_at
BEFORE UPDATE ON public.curated_live_topics
FOR EACH ROW
EXECUTE FUNCTION public.touch_curated_live_topics_updated_at();

ALTER TABLE public.curated_live_topics ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "curated_live_topics_read_active" ON public.curated_live_topics;
CREATE POLICY "curated_live_topics_read_active"
ON public.curated_live_topics
FOR SELECT
TO authenticated
USING (
  status = 'active'
  AND (starts_at IS NULL OR starts_at <= now())
  AND (expires_at IS NULL OR expires_at > now())
);

DROP POLICY IF EXISTS "admins_manage_curated_live_topics" ON public.curated_live_topics;
CREATE POLICY "admins_manage_curated_live_topics"
ON public.curated_live_topics
FOR ALL
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'events_ops', 'moderator']))
WITH CHECK (public.has_admin_role(ARRAY['super_admin', 'events_ops', 'moderator']));

INSERT INTO public.curated_live_topics (
  category,
  title,
  prompt,
  share_hook,
  status,
  featured,
  sort_order
) VALUES
  (
    'AI & Technology',
    'Will AI agents replace small business staff?',
    'Discuss whether AI agents will actually help small businesses grow revenue or just create more noise.',
    'I''m live on FaceMeet discussing whether AI agents will replace small business staff.',
    'active',
    true,
    10
  ),
  (
    'Business & Startups',
    'Would you invest if SpaceX goes public?',
    'Discuss whether a SpaceX IPO would be a once-in-a-generation opportunity or overhyped.',
    'I''m live on FaceMeet discussing whether people would invest in SpaceX if it goes public.',
    'active',
    true,
    20
  ),
  (
    'Sports',
    'What will decide the next big World Cup match?',
    'Discuss the players, tactics, and moments that could decide the match.',
    'I''m live on FaceMeet discussing what could decide the next big World Cup match.',
    'active',
    false,
    30
  ),
  (
    'Career & Money',
    'Is remote work ending or evolving?',
    'Discuss whether companies are right to bring people back to the office or whether remote work is here to stay.',
    'I''m live on FaceMeet discussing whether remote work is ending or evolving.',
    'active',
    false,
    40
  ),
  (
    'Local / Dallas',
    'What are Dallas founders building right now?',
    'Discuss the products, businesses, and ideas coming out of the Dallas builder community.',
    'I''m live on FaceMeet discussing what Dallas founders are building right now.',
    'active',
    false,
    50
  ),
  (
    'Culture',
    'Are people lonelier even though everyone is online?',
    'Discuss whether social apps have made people more connected or more isolated.',
    'I''m live on FaceMeet discussing whether people are lonelier even though everyone is online.',
    'active',
    true,
    60
  ),
  (
    'Relationships & Life',
    'What makes a real connection last?',
    'Discuss what actually creates trust, friendship, and meaningful connection between people.',
    'I''m live on FaceMeet discussing what makes a real connection last.',
    'active',
    false,
    70
  ),
  (
    'Product & Builders',
    'What makes users come back every day?',
    'Discuss retention, habits, product loops, and what makes a product worth returning to.',
    'I''m live on FaceMeet discussing what makes users come back every day.',
    'active',
    false,
    80
  )
ON CONFLICT (title) DO UPDATE
SET category = EXCLUDED.category,
    prompt = EXCLUDED.prompt,
    share_hook = EXCLUDED.share_hook,
    status = EXCLUDED.status,
    featured = EXCLUDED.featured,
    sort_order = EXCLUDED.sort_order,
    updated_at = now();

CREATE OR REPLACE FUNCTION public.list_active_curated_live_topics()
RETURNS SETOF public.curated_live_topics
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT *
  FROM public.curated_live_topics
  WHERE status = 'active'
    AND (starts_at IS NULL OR starts_at <= now())
    AND (expires_at IS NULL OR expires_at > now())
  ORDER BY featured DESC, sort_order ASC, created_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.create_live_topic_from_curated_topic(
  p_cohost_user_id UUID,
  p_curated_topic_id UUID,
  p_visibility TEXT DEFAULT 'link_only'
) RETURNS public.live_topics
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_topic public.live_topics%ROWTYPE;
  v_curated public.curated_live_topics%ROWTYPE;
  v_has_connection BOOLEAN;
  v_balance INTEGER;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;
  IF p_cohost_user_id IS NULL OR p_cohost_user_id = v_uid THEN
    RAISE EXCEPTION 'invalid_cohost';
  END IF;
  IF p_curated_topic_id IS NULL THEN
    RAISE EXCEPTION 'curated_topic_required';
  END IF;
  IF coalesce(p_visibility, 'link_only') NOT IN ('public', 'link_only', 'invite_only') THEN
    RAISE EXCEPTION 'invalid_visibility';
  END IF;

  SELECT *
  INTO v_curated
  FROM public.curated_live_topics
  WHERE id = p_curated_topic_id
    AND status = 'active'
    AND (starts_at IS NULL OR starts_at <= now())
    AND (expires_at IS NULL OR expires_at > now());

  IF NOT FOUND THEN
    RAISE EXCEPTION 'curated_topic_not_available';
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
    curated_topic_id,
    title,
    topic,
    description,
    visibility,
    status,
    spark_cost,
    duration_minutes,
    public_slug
  ) VALUES (
    v_uid,
    p_cohost_user_id,
    v_curated.id,
    trim(v_curated.title),
    trim(v_curated.category),
    trim(coalesce(nullif(v_curated.description, ''), v_curated.prompt)),
    coalesce(p_visibility, 'link_only'),
    'pending_cohost_acceptance',
    1,
    15,
    public.generate_live_topic_slug(v_curated.title)
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
    jsonb_build_object(
      'spark_cost', 1,
      'visibility', v_topic.visibility,
      'curated_topic_id', v_curated.id,
      'curated_category', v_curated.category
    )
  );

  RETURN v_topic;
END;
$$;

DROP FUNCTION IF EXISTS public.get_live_topic_by_slug(TEXT);
CREATE OR REPLACE FUNCTION public.get_live_topic_by_slug(p_slug TEXT)
RETURNS TABLE (
  id UUID,
  creator_user_id UUID,
  cohost_user_id UUID,
  curated_topic_id UUID,
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
  curated_category TEXT,
  curated_prompt TEXT,
  curated_share_hook TEXT,
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
    lt.curated_topic_id,
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
    clt.category AS curated_category,
    clt.prompt AS curated_prompt,
    clt.share_hook AS curated_share_hook,
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
  LEFT JOIN public.curated_live_topics clt ON clt.id = lt.curated_topic_id
  WHERE lt.public_slug = p_slug
    AND (
      lt.visibility IN ('public', 'link_only')
      OR lt.creator_user_id = auth.uid()
      OR lt.cohost_user_id = auth.uid()
    );
$$;

GRANT EXECUTE ON FUNCTION public.list_active_curated_live_topics() TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_live_topic_from_curated_topic(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_live_topic_by_slug(TEXT) TO authenticated;
