ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS access_mode text NOT NULL DEFAULT 'individual_request';

ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_access_mode_check;

ALTER TABLE public.events
  ADD CONSTRAINT events_access_mode_check
  CHECK (access_mode IN ('individual_request', 'pair_priority', 'match_unlocked', 'invite_only'));
