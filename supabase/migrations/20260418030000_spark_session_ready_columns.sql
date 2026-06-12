-- Add user_1_ready / user_2_ready boolean columns to spark_sessions
-- These replace the presence-only approach and are used to synchronise
-- the waiting room so both users launch the Daily.co call simultaneously.

ALTER TABLE public.spark_sessions
  ADD COLUMN IF NOT EXISTS user_1_ready BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS user_2_ready BOOLEAN DEFAULT false;

-- Add session_expired to match_status_type enum (used when 5-min timeout fires)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum
    WHERE enumlabel = 'session_expired'
      AND enumtypid = (
        SELECT oid FROM pg_type WHERE typname = 'match_status_type'
      )
  ) THEN
    ALTER TYPE public.match_status_type ADD VALUE 'session_expired';
  END IF;
END;
$$;

-- Index for fast ready-state lookups
CREATE INDEX IF NOT EXISTS idx_spark_sessions_ready
  ON public.spark_sessions(match_id, user_1_ready, user_2_ready);
