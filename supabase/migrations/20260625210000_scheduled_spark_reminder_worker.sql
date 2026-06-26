ALTER TABLE public.spark_session_schedules
  ADD COLUMN IF NOT EXISTS reminder_sent_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS join_ready_sent_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_spark_session_schedules_reminder_due
  ON public.spark_session_schedules(accepted_time)
  WHERE status = 'accepted'
    AND reminder_sent_at IS NULL
    AND accepted_time IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_spark_session_schedules_join_ready_due
  ON public.spark_session_schedules(accepted_time)
  WHERE status = 'accepted'
    AND join_ready_sent_at IS NULL
    AND accepted_time IS NOT NULL;
