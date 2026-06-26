CREATE TABLE IF NOT EXISTS public.spark_session_schedules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  spark_session_id UUID REFERENCES public.spark_sessions(id) ON DELETE SET NULL,
  proposer_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  recipient_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  spark_type TEXT NOT NULL DEFAULT 'dating',
  proposed_times TIMESTAMPTZ[] NOT NULL DEFAULT ARRAY[]::TIMESTAMPTZ[],
  accepted_time TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'proposed',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT spark_session_schedules_status_check
    CHECK (status IN ('proposed', 'accepted', 'declined', 'countered', 'cancelled', 'expired')),
  CONSTRAINT spark_session_schedules_spark_type_check
    CHECK (spark_type IN ('dating', 'friendship', 'professional', 'events')),
  CONSTRAINT spark_session_schedules_participants_check
    CHECK (proposer_user_id <> recipient_user_id)
);

CREATE INDEX IF NOT EXISTS idx_spark_session_schedules_match
  ON public.spark_session_schedules(match_id);

CREATE INDEX IF NOT EXISTS idx_spark_session_schedules_proposer
  ON public.spark_session_schedules(proposer_user_id);

CREATE INDEX IF NOT EXISTS idx_spark_session_schedules_recipient
  ON public.spark_session_schedules(recipient_user_id);

CREATE INDEX IF NOT EXISTS idx_spark_session_schedules_status_time
  ON public.spark_session_schedules(status, accepted_time);

CREATE UNIQUE INDEX IF NOT EXISTS idx_spark_session_schedules_one_active_match
  ON public.spark_session_schedules(match_id)
  WHERE status IN ('proposed', 'accepted', 'countered');

ALTER TABLE public.spark_session_schedules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_read_own_spark_session_schedules"
  ON public.spark_session_schedules;
CREATE POLICY "users_read_own_spark_session_schedules"
ON public.spark_session_schedules
FOR SELECT
USING (
  auth.uid() = proposer_user_id OR auth.uid() = recipient_user_id
);

DROP POLICY IF EXISTS "users_insert_own_spark_session_schedules"
  ON public.spark_session_schedules;
CREATE POLICY "users_insert_own_spark_session_schedules"
ON public.spark_session_schedules
FOR INSERT
WITH CHECK (
  auth.uid() = proposer_user_id
  AND EXISTS (
    SELECT 1
    FROM public.matches m
    WHERE m.id = match_id
      AND (m.user_1_id = auth.uid() OR m.user_2_id = auth.uid())
      AND m.status IN ('matched_pending_session', 'session_expired')
  )
);

DROP POLICY IF EXISTS "users_update_own_spark_session_schedules"
  ON public.spark_session_schedules;
CREATE POLICY "users_update_own_spark_session_schedules"
ON public.spark_session_schedules
FOR UPDATE
USING (
  auth.uid() = proposer_user_id OR auth.uid() = recipient_user_id
)
WITH CHECK (
  auth.uid() = proposer_user_id OR auth.uid() = recipient_user_id
);

CREATE OR REPLACE FUNCTION public.touch_spark_session_schedule_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_spark_session_schedule_updated_at
  ON public.spark_session_schedules;
CREATE TRIGGER trg_touch_spark_session_schedule_updated_at
BEFORE UPDATE ON public.spark_session_schedules
FOR EACH ROW
EXECUTE FUNCTION public.touch_spark_session_schedule_updated_at();

CREATE OR REPLACE FUNCTION public.normalize_spark_schedule_times(
  p_times TIMESTAMPTZ[]
)
RETURNS TIMESTAMPTZ[]
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    ARRAY(
      SELECT DISTINCT proposed_time
      FROM unnest(COALESCE(p_times, ARRAY[]::TIMESTAMPTZ[])) AS proposed_time
      WHERE proposed_time > NOW() - INTERVAL '5 minutes'
      ORDER BY proposed_time
      LIMIT 3
    ),
    ARRAY[]::TIMESTAMPTZ[]
  );
$$;

CREATE OR REPLACE FUNCTION public.latest_spark_type_for_match(
  p_match_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_spark_type TEXT;
BEGIN
  SELECT *
  INTO v_match
  FROM public.matches
  WHERE id = p_match_id;

  IF NOT FOUND THEN
    RETURN 'dating';
  END IF;

  SELECT COALESCE(i.spark_type, 'dating')
  INTO v_spark_type
  FROM public.interactions i
  WHERE i.action_type = 'spark'
    AND (
      (i.from_user_id = v_match.user_1_id AND i.to_user_id = v_match.user_2_id)
      OR
      (i.from_user_id = v_match.user_2_id AND i.to_user_id = v_match.user_1_id)
    )
  ORDER BY i.created_at DESC
  LIMIT 1;

  RETURN COALESCE(v_spark_type, 'dating');
END;
$$;

CREATE OR REPLACE FUNCTION public.create_spark_session_schedule(
  p_match_id UUID,
  p_proposed_times TIMESTAMPTZ[]
)
RETURNS public.spark_session_schedules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_match public.matches%ROWTYPE;
  v_recipient UUID;
  v_times TIMESTAMPTZ[];
  v_schedule public.spark_session_schedules%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT *
  INTO v_match
  FROM public.matches
  WHERE id = p_match_id
    AND (user_1_id = v_uid OR user_2_id = v_uid)
    AND status IN ('matched_pending_session', 'session_expired');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_requires_mutual_spark';
  END IF;

  v_recipient := CASE
    WHEN v_match.user_1_id = v_uid THEN v_match.user_2_id
    ELSE v_match.user_1_id
  END;

  v_times := public.normalize_spark_schedule_times(p_proposed_times);
  IF COALESCE(array_length(v_times, 1), 0) = 0 THEN
    RAISE EXCEPTION 'schedule_requires_future_time';
  END IF;

  SELECT *
  INTO v_schedule
  FROM public.spark_session_schedules
  WHERE match_id = p_match_id
    AND status IN ('proposed', 'accepted', 'countered')
  LIMIT 1;

  IF FOUND THEN
    UPDATE public.spark_session_schedules
    SET proposer_user_id = v_uid,
        recipient_user_id = v_recipient,
        spark_type = public.latest_spark_type_for_match(p_match_id),
        proposed_times = v_times,
        accepted_time = NULL,
        status = 'proposed'
    WHERE id = v_schedule.id
    RETURNING * INTO v_schedule;
  ELSE
    INSERT INTO public.spark_session_schedules (
      match_id,
      proposer_user_id,
      recipient_user_id,
      spark_type,
      proposed_times,
      status
    )
    VALUES (
      p_match_id,
      v_uid,
      v_recipient,
      public.latest_spark_type_for_match(p_match_id),
      v_times,
      'proposed'
    )
    RETURNING * INTO v_schedule;
  END IF;

  RETURN v_schedule;
END;
$$;

CREATE OR REPLACE FUNCTION public.accept_spark_session_schedule(
  p_schedule_id UUID,
  p_accepted_time TIMESTAMPTZ
)
RETURNS public.spark_session_schedules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_schedule public.spark_session_schedules%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT *
  INTO v_schedule
  FROM public.spark_session_schedules
  WHERE id = p_schedule_id
    AND (proposer_user_id = v_uid OR recipient_user_id = v_uid)
    AND status IN ('proposed', 'countered');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_not_available';
  END IF;

  IF p_accepted_time IS NULL THEN
    RAISE EXCEPTION 'accepted_time_required';
  END IF;

  UPDATE public.spark_session_schedules
  SET accepted_time = p_accepted_time,
      status = 'accepted'
  WHERE id = p_schedule_id
  RETURNING * INTO v_schedule;

  RETURN v_schedule;
END;
$$;

CREATE OR REPLACE FUNCTION public.counter_spark_session_schedule(
  p_schedule_id UUID,
  p_proposed_times TIMESTAMPTZ[]
)
RETURNS public.spark_session_schedules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_schedule public.spark_session_schedules%ROWTYPE;
  v_recipient UUID;
  v_times TIMESTAMPTZ[];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT *
  INTO v_schedule
  FROM public.spark_session_schedules
  WHERE id = p_schedule_id
    AND (proposer_user_id = v_uid OR recipient_user_id = v_uid)
    AND status IN ('proposed', 'countered', 'accepted');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_not_available';
  END IF;

  v_times := public.normalize_spark_schedule_times(p_proposed_times);
  IF COALESCE(array_length(v_times, 1), 0) = 0 THEN
    RAISE EXCEPTION 'schedule_requires_future_time';
  END IF;

  v_recipient := CASE
    WHEN v_schedule.proposer_user_id = v_uid THEN v_schedule.recipient_user_id
    ELSE v_schedule.proposer_user_id
  END;

  UPDATE public.spark_session_schedules
  SET proposer_user_id = v_uid,
      recipient_user_id = v_recipient,
      proposed_times = v_times,
      accepted_time = NULL,
      status = 'countered'
  WHERE id = p_schedule_id
  RETURNING * INTO v_schedule;

  RETURN v_schedule;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_spark_session_schedule(
  p_schedule_id UUID
)
RETURNS public.spark_session_schedules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_schedule public.spark_session_schedules%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  UPDATE public.spark_session_schedules
  SET status = 'cancelled'
  WHERE id = p_schedule_id
    AND (proposer_user_id = v_uid OR recipient_user_id = v_uid)
    AND status IN ('proposed', 'accepted', 'countered')
  RETURNING * INTO v_schedule;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_not_available';
  END IF;

  RETURN v_schedule;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_scheduled_spark_sessions()
RETURNS SETOF public.spark_session_schedules
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.*
  FROM public.spark_session_schedules s
  JOIN public.matches m ON m.id = s.match_id
  WHERE auth.uid() IS NOT NULL
    AND (s.proposer_user_id = auth.uid() OR s.recipient_user_id = auth.uid())
    AND (m.user_1_id = auth.uid() OR m.user_2_id = auth.uid())
    AND s.status IN ('proposed', 'accepted', 'countered')
  ORDER BY COALESCE(s.accepted_time, s.proposed_times[1], s.created_at) ASC;
$$;

REVOKE ALL ON FUNCTION public.create_spark_session_schedule(UUID, TIMESTAMPTZ[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.accept_spark_session_schedule(UUID, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.counter_spark_session_schedule(UUID, TIMESTAMPTZ[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_spark_session_schedule(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_scheduled_spark_sessions() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_spark_session_schedule(UUID, TIMESTAMPTZ[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_spark_session_schedule(UUID, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.counter_spark_session_schedule(UUID, TIMESTAMPTZ[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_spark_session_schedule(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_scheduled_spark_sessions() TO authenticated;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_publication
    WHERE pubname = 'supabase_realtime'
  ) THEN
    BEGIN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.spark_session_schedules;
    EXCEPTION
      WHEN duplicate_object THEN NULL;
    END;
  END IF;
END $$;
