ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS guest_list_status text NOT NULL DEFAULT 'open',
  ADD COLUMN IF NOT EXISTS video_required boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS verification_required boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS access_note text;

ALTER TABLE public.events
  DROP CONSTRAINT IF EXISTS events_guest_list_status_check;

ALTER TABLE public.events
  ADD CONSTRAINT events_guest_list_status_check
  CHECK (guest_list_status IN ('open', 'limited', 'finalizing', 'full', 'closed'));
