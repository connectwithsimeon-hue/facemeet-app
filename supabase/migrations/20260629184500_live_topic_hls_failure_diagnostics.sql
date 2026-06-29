-- Safe persistent diagnostics for Live Topic HLS failures.
-- Stores only sanitized error metadata: no secrets, URLs, keys, JWTs, or user emails.

ALTER TABLE public.live_topics
  ADD COLUMN IF NOT EXISTS hls_last_error_code TEXT,
  ADD COLUMN IF NOT EXISTS hls_last_error_message TEXT,
  ADD COLUMN IF NOT EXISTS hls_last_error_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS hls_last_daily_status INTEGER,
  ADD COLUMN IF NOT EXISTS hls_last_daily_response_keys TEXT[];

CREATE INDEX IF NOT EXISTS idx_live_topics_hls_last_error_at
  ON public.live_topics (hls_last_error_at DESC)
  WHERE hls_last_error_at IS NOT NULL;
