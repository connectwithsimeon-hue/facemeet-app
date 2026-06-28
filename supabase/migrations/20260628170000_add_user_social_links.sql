-- FaceMeet Social Links foundation.
-- Stores public social links/handles only. No OAuth tokens or API credentials.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS social_links JSONB NOT NULL DEFAULT '{}'::JSONB;

COMMENT ON COLUMN public.users.social_links IS
  'Public social profile links/handles for display/share context only. Does not store OAuth tokens.';
