-- Async Matching Flow Migration
-- Adds user_presence tracking to spark_sessions for Realtime waiting room detection

-- Add user_presence column to spark_sessions to track who has entered the waiting room
ALTER TABLE public.spark_sessions
  ADD COLUMN IF NOT EXISTS user_1_present BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS user_2_present BOOLEAN DEFAULT false;

-- Add index for faster presence lookups
CREATE INDEX IF NOT EXISTS idx_spark_sessions_presence
  ON public.spark_sessions(match_id, user_1_present, user_2_present);

-- Enable Realtime for spark_sessions so waiting room can detect both users present
-- (Realtime is enabled via Supabase dashboard; this ensures the table is in the publication)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'spark_sessions'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.spark_sessions;
  END IF;
END;
$$;

-- Enable Realtime for matches so the banner can detect new mutual matches
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'matches'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.matches;
  END IF;
END;
$$;
