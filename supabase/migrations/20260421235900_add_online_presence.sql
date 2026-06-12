-- Add online presence columns to users table
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS is_online boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;

-- Index for fast queries on online users
CREATE INDEX IF NOT EXISTS idx_users_is_online ON public.users (is_online);
CREATE INDEX IF NOT EXISTS idx_users_last_seen_at ON public.users (last_seen_at);

-- Cleanup function: mark users offline if last_seen_at is older than 5 minutes
CREATE OR REPLACE FUNCTION public.cleanup_offline_users()
RETURNS void AS $$
BEGIN
  UPDATE public.users
  SET is_online = false
  WHERE is_online = true
    AND last_seen_at < now() - INTERVAL '5 minutes';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Schedule cleanup every minute using pg_cron (if available)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'
  ) THEN
    PERFORM cron.schedule(
      'cleanup_offline_users',
      '* * * * *',
      'SELECT public.cleanup_offline_users()'
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- pg_cron not available, cleanup will be handled by app lifecycle
  NULL;
END;
$$;
