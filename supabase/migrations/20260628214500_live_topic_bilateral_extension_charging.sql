-- Live Topic bilateral extension charging.
-- Creates an idempotent extension charge marker and charges host/co-host
-- atomically before extending the room timer.

CREATE TABLE IF NOT EXISTS public.live_topic_extension_charges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  live_topic_id UUID NOT NULL REFERENCES public.live_topics(id) ON DELETE CASCADE,
  extension_key TEXT NOT NULL,
  requested_by UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  host_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  cohost_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  spark_cost_each INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT live_topic_extension_charges_cost_check CHECK (spark_cost_each = 1),
  CONSTRAINT live_topic_extension_charges_unique_key UNIQUE (live_topic_id, extension_key)
);

CREATE INDEX IF NOT EXISTS idx_live_topic_extension_charges_topic
  ON public.live_topic_extension_charges(live_topic_id, created_at DESC);

ALTER TABLE public.live_topic_extension_charges ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "live_topic_extension_charges_read_related"
ON public.live_topic_extension_charges;
CREATE POLICY "live_topic_extension_charges_read_related"
ON public.live_topic_extension_charges
FOR SELECT
USING (public.is_live_topic_host_or_cohost(live_topic_id, auth.uid()));

DROP FUNCTION IF EXISTS public.extend_live_topic(UUID);
CREATE OR REPLACE FUNCTION public.extend_live_topic(
  p_live_topic_id UUID,
  p_extension_key TEXT DEFAULT NULL
) RETURNS public.live_topics
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_topic public.live_topics%ROWTYPE;
  v_updated public.live_topics%ROWTYPE;
  v_host_balance INTEGER;
  v_cohost_balance INTEGER;
  v_extension_key TEXT := NULLIF(trim(coalesce(p_extension_key, '')), '');
  v_charge_id UUID;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

  SELECT *
  INTO v_topic
  FROM public.live_topics
  WHERE id = p_live_topic_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'live_topic_not_found'; END IF;
  IF v_topic.status <> 'live' THEN RAISE EXCEPTION 'topic_not_live'; END IF;
  IF v_uid <> v_topic.creator_user_id AND v_uid <> v_topic.cohost_user_id THEN
    RAISE EXCEPTION 'not_host_or_cohost';
  END IF;
  IF v_topic.creator_user_id IS NULL OR v_topic.cohost_user_id IS NULL THEN
    RAISE EXCEPTION 'extension_requires_both_hosts';
  END IF;

  IF v_extension_key IS NULL THEN
    v_extension_key := gen_random_uuid()::TEXT;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.live_topic_extension_charges
    WHERE live_topic_id = p_live_topic_id
      AND extension_key = v_extension_key
  ) THEN
    RETURN v_topic;
  END IF;

  SELECT spark_balance
  INTO v_host_balance
  FROM public.users
  WHERE id = v_topic.creator_user_id
  FOR UPDATE;

  SELECT spark_balance
  INTO v_cohost_balance
  FROM public.users
  WHERE id = v_topic.cohost_user_id
  FOR UPDATE;

  IF coalesce(v_host_balance, 0) < 1 THEN
    IF v_uid = v_topic.creator_user_id THEN
      RAISE EXCEPTION 'insufficient_sparks';
    END IF;
    RAISE EXCEPTION 'host_insufficient_sparks';
  END IF;

  IF coalesce(v_cohost_balance, 0) < 1 THEN
    IF v_uid = v_topic.cohost_user_id THEN
      RAISE EXCEPTION 'insufficient_sparks';
    END IF;
    RAISE EXCEPTION 'cohost_insufficient_sparks';
  END IF;

  INSERT INTO public.live_topic_extension_charges(
    live_topic_id,
    extension_key,
    requested_by,
    host_user_id,
    cohost_user_id,
    spark_cost_each
  ) VALUES (
    p_live_topic_id,
    v_extension_key,
    v_uid,
    v_topic.creator_user_id,
    v_topic.cohost_user_id,
    1
  )
  ON CONFLICT (live_topic_id, extension_key) DO NOTHING
  RETURNING id INTO v_charge_id;

  IF v_charge_id IS NULL THEN
    RETURN v_topic;
  END IF;

  UPDATE public.users
  SET spark_balance = spark_balance - 1
  WHERE id IN (v_topic.creator_user_id, v_topic.cohost_user_id);

  UPDATE public.live_topics
  SET ends_at = greatest(coalesce(ends_at, now()), now()) + interval '15 minutes',
      extension_count = extension_count + 1
  WHERE id = p_live_topic_id
    AND status = 'live'
  RETURNING * INTO v_updated;

  IF NOT FOUND THEN RAISE EXCEPTION 'topic_not_live'; END IF;

  INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type, metadata)
  VALUES (
    p_live_topic_id,
    v_uid,
    'live_topic_extended',
    jsonb_build_object(
      'spark_cost_each', 1,
      'total_spark_cost', 2,
      'extension_key', v_extension_key
    )
  );

  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public.extend_live_topic(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.extend_live_topic(UUID, TEXT) TO authenticated;
