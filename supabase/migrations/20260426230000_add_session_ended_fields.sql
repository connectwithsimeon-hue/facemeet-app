-- Add status, ended_by columns to spark_sessions for synchronized session ending
ALTER TABLE public.spark_sessions
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS ended_by uuid REFERENCES auth.users(id);

-- Index for fast realtime lookups by match_id
CREATE INDEX IF NOT EXISTS idx_spark_sessions_match_id ON public.spark_sessions(match_id);
