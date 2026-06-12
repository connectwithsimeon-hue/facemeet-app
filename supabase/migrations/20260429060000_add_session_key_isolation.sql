-- Add session_key to spark_sessions for unique per-attempt isolation
ALTER TABLE public.spark_sessions
ADD COLUMN IF NOT EXISTS session_key TEXT;

-- Add current_session_key to matches so both users can coordinate on the exact same attempt
ALTER TABLE public.matches
ADD COLUMN IF NOT EXISTS current_session_key TEXT;

-- Index for fast lookup by session_key
CREATE INDEX IF NOT EXISTS idx_spark_sessions_session_key ON public.spark_sessions(session_key);
