-- Add metro_area column to users table for launch targeting
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS metro_area TEXT;

-- Index for filtering users by metro area
CREATE INDEX IF NOT EXISTS idx_users_metro_area ON public.users(metro_area);
