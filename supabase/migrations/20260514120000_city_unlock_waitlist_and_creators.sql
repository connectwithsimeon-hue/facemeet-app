-- FaceMeet city-by-city waitlist and creator applications.

ALTER TABLE public.founding_applications
  ADD COLUMN IF NOT EXISTS phone TEXT,
  ADD COLUMN IF NOT EXISTS dating_preference TEXT,
  ADD COLUMN IF NOT EXISTS age_confirmed BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS launch_updates_consent BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS selected_city_slug TEXT,
  ADD COLUMN IF NOT EXISTS referral_source TEXT;

CREATE TABLE IF NOT EXISTS public.city_unlock_markets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  city_name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'waitlist',
  unlock_target INTEGER NOT NULL DEFAULT 500,
  verified_count INTEGER NOT NULL DEFAULT 0,
  profile_upload_count INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 100,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT city_unlock_markets_status_check
    CHECK (status IN ('waitlist', 'profile_upload', 'beta_live', 'public_live'))
);

CREATE INDEX IF NOT EXISTS idx_city_unlock_markets_slug
  ON public.city_unlock_markets(slug);

CREATE INDEX IF NOT EXISTS idx_city_unlock_markets_sort
  ON public.city_unlock_markets(sort_order);

INSERT INTO public.city_unlock_markets
  (city_name, slug, status, unlock_target, verified_count, profile_upload_count, sort_order)
VALUES
  ('Dallas-Fort Worth', 'dallas-fort-worth', 'beta_live', 500, 135, 0, 1),
  ('Houston', 'houston', 'waitlist', 500, 0, 0, 2),
  ('Austin', 'austin', 'waitlist', 500, 0, 0, 3),
  ('San Antonio', 'san-antonio', 'waitlist', 500, 0, 0, 4),
  ('Los Angeles', 'los-angeles', 'waitlist', 500, 0, 0, 5),
  ('Miami / South Florida', 'miami-south-florida', 'waitlist', 500, 0, 0, 6),
  ('New York City', 'new-york-city', 'waitlist', 500, 0, 0, 7),
  ('Atlanta', 'atlanta', 'waitlist', 500, 0, 0, 8),
  ('Chicago', 'chicago', 'waitlist', 500, 0, 0, 9),
  ('Philadelphia', 'philadelphia', 'waitlist', 500, 0, 0, 10)
ON CONFLICT (slug) DO UPDATE SET
  city_name = EXCLUDED.city_name,
  unlock_target = EXCLUDED.unlock_target,
  sort_order = EXCLUDED.sort_order,
  updated_at = CURRENT_TIMESTAMP;

CREATE TABLE IF NOT EXISTS public.creator_applications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name TEXT NOT NULL,
  email TEXT NOT NULL,
  phone TEXT,
  city TEXT NOT NULL,
  tiktok_handle TEXT,
  instagram_handle TEXT,
  primary_platform TEXT,
  tiktok_followers TEXT,
  instagram_followers TEXT,
  average_views TEXT,
  content_niche TEXT,
  audience_location TEXT,
  why_promote TEXT,
  payout_preference TEXT,
  agreement_accepted BOOLEAN NOT NULL DEFAULT false,
  referral_source TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT creator_applications_status_check
    CHECK (status IN ('pending', 'approved', 'waitlist', 'rejected'))
);

CREATE INDEX IF NOT EXISTS idx_creator_applications_created_at
  ON public.creator_applications(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_creator_applications_status
  ON public.creator_applications(status);

ALTER TABLE public.city_unlock_markets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_applications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "public_read_city_unlock_markets" ON public.city_unlock_markets;
CREATE POLICY "public_read_city_unlock_markets"
ON public.city_unlock_markets
FOR SELECT
USING (true);

DROP POLICY IF EXISTS "anon_insert_creator_applications" ON public.creator_applications;
CREATE POLICY "anon_insert_creator_applications"
ON public.creator_applications
FOR INSERT
WITH CHECK (agreement_accepted = true);

