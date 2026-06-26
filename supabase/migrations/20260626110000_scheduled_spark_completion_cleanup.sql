ALTER TABLE public.spark_session_schedules
  ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;

ALTER TABLE public.spark_session_schedules
  DROP CONSTRAINT IF EXISTS spark_session_schedules_status_check;

ALTER TABLE public.spark_session_schedules
  ADD CONSTRAINT spark_session_schedules_status_check
    CHECK (status IN ('proposed', 'accepted', 'declined', 'countered', 'cancelled', 'expired', 'completed'));

CREATE INDEX IF NOT EXISTS idx_spark_session_schedules_completed_at
  ON public.spark_session_schedules(completed_at)
  WHERE completed_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public.complete_spark_session_schedule_for_match(
  p_match_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_updated_count INTEGER := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.matches m
    WHERE m.id = p_match_id
      AND (m.user_1_id = v_uid OR m.user_2_id = v_uid)
  ) THEN
    RAISE EXCEPTION 'match_not_available';
  END IF;

  UPDATE public.spark_session_schedules s
  SET status = 'completed',
      completed_at = COALESCE(s.completed_at, NOW())
  WHERE s.match_id = p_match_id
    AND (s.proposer_user_id = v_uid OR s.recipient_user_id = v_uid)
    AND s.status IN ('proposed', 'accepted', 'countered')
    AND s.completed_at IS NULL;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN v_updated_count;
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
    AND s.completed_at IS NULL
    AND m.status NOT IN ('chat_unlocked', 'session_ended')
  ORDER BY COALESCE(s.accepted_time, s.proposed_times[1], s.created_at) ASC;
$$;

REVOKE ALL ON FUNCTION public.complete_spark_session_schedule_for_match(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_scheduled_spark_sessions() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.complete_spark_session_schedule_for_match(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_scheduled_spark_sessions() TO authenticated;

UPDATE public.spark_session_schedules s
SET status = 'completed',
    completed_at = COALESCE(s.completed_at, NOW())
FROM public.matches m
WHERE m.id = s.match_id
  AND s.status IN ('proposed', 'accepted', 'countered')
  AND s.completed_at IS NULL
  AND m.status IN ('chat_unlocked', 'session_ended');
