-- Phase 1 automated profile video moderation.
-- Videos are hidden from Discover unless moderation_status = 'approved'.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS moderation_status TEXT NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS moderation_reason TEXT,
  ADD COLUMN IF NOT EXISTS moderated_at TIMESTAMPTZ;

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_moderation_status_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_moderation_status_check
  CHECK (moderation_status IN ('pending', 'approved', 'rejected', 'needs_review'));

CREATE INDEX IF NOT EXISTS idx_users_moderation_status
  ON public.users(moderation_status);

CREATE INDEX IF NOT EXISTS idx_users_discoverable_video
  ON public.users(onboarding_complete, moderation_status, last_active);

-- Preserve the current working app baseline: existing completed profiles with a
-- profile video were previously visible in Discover, so backfill them approved.
UPDATE public.users
SET
  moderation_status = 'approved',
  moderation_reason = COALESCE(moderation_reason, 'Backfilled existing profile video before automated moderation launch.'),
  moderated_at = COALESCE(moderated_at, now())
WHERE
  onboarding_complete = true
  AND COALESCE(profile_video_url, '') <> ''
  AND moderation_status = 'pending';
