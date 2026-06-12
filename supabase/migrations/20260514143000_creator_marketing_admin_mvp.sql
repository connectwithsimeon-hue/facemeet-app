-- FaceMeet creator partner and influencer marketing admin MVP.

CREATE TABLE IF NOT EXISTS public.cities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  city_name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  state_or_region TEXT,
  status TEXT NOT NULL DEFAULT 'waitlist',
  unlock_target INTEGER NOT NULL DEFAULT 500,
  total_waitlist_count INTEGER NOT NULL DEFAULT 0,
  verified_waitlist_count INTEGER NOT NULL DEFAULT 0,
  profile_upload_count INTEGER NOT NULL DEFAULT 0,
  active_creator_count INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT cities_status_check CHECK (status IN ('waitlist', 'profile_upload', 'beta_live', 'public_live'))
);

INSERT INTO public.cities
  (city_name, slug, state_or_region, status, unlock_target, total_waitlist_count, verified_waitlist_count, profile_upload_count, active_creator_count)
VALUES
  ('Dallas-Fort Worth', 'dallas-fort-worth', 'Texas', 'beta_live', 500, 135, 135, 0, 0),
  ('Houston', 'houston', 'Texas', 'waitlist', 500, 0, 0, 0, 0),
  ('Austin', 'austin', 'Texas', 'waitlist', 500, 0, 0, 0, 0),
  ('San Antonio', 'san-antonio', 'Texas', 'waitlist', 500, 0, 0, 0, 0),
  ('Los Angeles', 'los-angeles', 'California', 'waitlist', 500, 0, 0, 0, 0),
  ('Miami / South Florida', 'miami-south-florida', 'Florida', 'waitlist', 500, 0, 0, 0, 0),
  ('New York City', 'new-york-city', 'New York', 'waitlist', 500, 0, 0, 0, 0),
  ('Atlanta', 'atlanta', 'Georgia', 'waitlist', 500, 0, 0, 0, 0),
  ('Chicago', 'chicago', 'Illinois', 'waitlist', 500, 0, 0, 0, 0),
  ('Philadelphia', 'philadelphia', 'Pennsylvania', 'waitlist', 500, 0, 0, 0, 0)
ON CONFLICT (slug) DO UPDATE SET
  city_name = EXCLUDED.city_name,
  state_or_region = EXCLUDED.state_or_region,
  unlock_target = EXCLUDED.unlock_target,
  updated_at = CURRENT_TIMESTAMP;

CREATE TABLE IF NOT EXISTS public.creators (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  city TEXT,
  city_slug TEXT,
  platform_priority TEXT,
  tiktok_handle TEXT,
  instagram_handle TEXT,
  tiktok_followers INTEGER DEFAULT 0,
  instagram_followers INTEGER DEFAULT 0,
  average_views INTEGER DEFAULT 0,
  content_niche TEXT,
  audience_city TEXT,
  audience_notes TEXT,
  fit_score INTEGER DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'prospect',
  referral_code TEXT UNIQUE,
  referral_link TEXT,
  payout_preference TEXT,
  notes TEXT,
  approved_posts INTEGER NOT NULL DEFAULT 0,
  total_visits INTEGER NOT NULL DEFAULT 0,
  waitlist_signups INTEGER NOT NULL DEFAULT 0,
  verified_signups INTEGER NOT NULL DEFAULT 0,
  phone_verified_signups INTEGER NOT NULL DEFAULT 0,
  profile_uploads INTEGER NOT NULL DEFAULT 0,
  paid_conversions INTEGER NOT NULL DEFAULT 0,
  last_contacted_at TIMESTAMPTZ,
  next_follow_up_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT creators_status_check CHECK (status IN (
    'applicant','prospect','ready_to_contact','contacted','follow_up_1_due','follow_up_2_due',
    'final_follow_up_due','no_response','replied','interested','not_interested','approved',
    'rejected','posted','paused','paid'
  ))
);

CREATE INDEX IF NOT EXISTS idx_creators_city_slug ON public.creators(city_slug);
CREATE INDEX IF NOT EXISTS idx_creators_status ON public.creators(status);
CREATE INDEX IF NOT EXISTS idx_creators_referral_code ON public.creators(referral_code);

ALTER TABLE public.creator_applications
  ADD COLUMN IF NOT EXISTS platform_priority TEXT,
  ADD COLUMN IF NOT EXISTS audience_city TEXT,
  ADD COLUMN IF NOT EXISTS audience_notes TEXT,
  ADD COLUMN IF NOT EXISTS fit_score INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS referral_code TEXT,
  ADD COLUMN IF NOT EXISTS referral_link TEXT,
  ADD COLUMN IF NOT EXISTS notes TEXT,
  ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS public.creator_referrals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id UUID REFERENCES public.creators(id) ON DELETE SET NULL,
  referral_code TEXT NOT NULL,
  total_visits INTEGER NOT NULL DEFAULT 0,
  waitlist_signups INTEGER NOT NULL DEFAULT 0,
  verified_signups INTEGER NOT NULL DEFAULT 0,
  phone_verified_signups INTEGER NOT NULL DEFAULT 0,
  profile_uploads INTEGER NOT NULL DEFAULT 0,
  paid_conversions INTEGER NOT NULL DEFAULT 0,
  last_visit_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(referral_code)
);

CREATE TABLE IF NOT EXISTS public.creator_communications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id UUID REFERENCES public.creators(id) ON DELETE CASCADE,
  channel TEXT NOT NULL DEFAULT 'Other',
  message_type TEXT NOT NULL DEFAULT 'custom',
  message_body TEXT,
  sent_by_admin TEXT,
  status TEXT DEFAULT 'logged',
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.creator_payouts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id UUID REFERENCES public.creators(id) ON DELETE CASCADE,
  approved_posts INTEGER NOT NULL DEFAULT 0,
  verified_signups INTEGER NOT NULL DEFAULT 0,
  signup_bonus NUMERIC(10,2) NOT NULL DEFAULT 0,
  city_unlock_bonus NUMERIC(10,2) NOT NULL DEFAULT 0,
  subscription_commission NUMERIC(10,2) NOT NULL DEFAULT 0,
  total_due NUMERIC(10,2) NOT NULL DEFAULT 0,
  payout_status TEXT NOT NULL DEFAULT 'unpaid',
  paid_at TIMESTAMPTZ,
  payment_notes TEXT,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT creator_payouts_status_check CHECK (payout_status IN ('unpaid','pending_review','approved','paid','disputed'))
);

CREATE TABLE IF NOT EXISTS public.waitlist_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name TEXT,
  email TEXT,
  phone TEXT,
  city TEXT,
  city_slug TEXT,
  gender TEXT,
  dating_preference TEXT,
  referral_code TEXT,
  creator_id UUID REFERENCES public.creators(id) ON DELETE SET NULL,
  is_verified BOOLEAN NOT NULL DEFAULT false,
  phone_verified BOOLEAN NOT NULL DEFAULT false,
  profile_uploaded BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.user_referrals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  waitlist_user_id UUID REFERENCES public.waitlist_users(id) ON DELETE CASCADE,
  creator_id UUID REFERENCES public.creators(id) ON DELETE SET NULL,
  referral_code TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS public.city_status_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  city_id UUID REFERENCES public.cities(id) ON DELETE CASCADE,
  old_status TEXT,
  new_status TEXT NOT NULL,
  changed_by TEXT,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION public.record_creator_referral_visit(p_referral_code TEXT, p_path TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  matched_creator_id UUID;
BEGIN
  IF p_referral_code IS NULL OR length(trim(p_referral_code)) = 0 THEN
    RETURN;
  END IF;

  SELECT id INTO matched_creator_id
  FROM public.creators
  WHERE referral_code = trim(p_referral_code)
  LIMIT 1;

  INSERT INTO public.creator_referrals (creator_id, referral_code, total_visits, last_visit_at)
  VALUES (matched_creator_id, trim(p_referral_code), 1, CURRENT_TIMESTAMP)
  ON CONFLICT (referral_code) DO UPDATE SET
    total_visits = public.creator_referrals.total_visits + 1,
    creator_id = COALESCE(public.creator_referrals.creator_id, EXCLUDED.creator_id),
    last_visit_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP;

  IF matched_creator_id IS NOT NULL THEN
    UPDATE public.creators
    SET total_visits = total_visits + 1,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = matched_creator_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_creator_referral_visit(TEXT, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.record_creator_referral_visit(TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.sync_creator_referral_from_founding_application()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  referral TEXT;
  matched_creator_id UUID;
  signup_delta INTEGER := 0;
  verified_delta INTEGER := 0;
BEGIN
  referral := NULLIF(trim(COALESCE(NEW.referred_by, NEW.referral_source, '')), '');
  IF referral IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT id INTO matched_creator_id
  FROM public.creators
  WHERE referral_code = referral
  LIMIT 1;

  IF TG_OP = 'INSERT' THEN
    signup_delta := 1;
    verified_delta := CASE WHEN COALESCE(NEW.status, 'pending') = 'approved' THEN 1 ELSE 0 END;
  ELSIF TG_OP = 'UPDATE' THEN
    signup_delta := 0;
    verified_delta := CASE
      WHEN COALESCE(OLD.status, 'pending') <> 'approved' AND COALESCE(NEW.status, 'pending') = 'approved' THEN 1
      WHEN COALESCE(OLD.status, 'pending') = 'approved' AND COALESCE(NEW.status, 'pending') <> 'approved' THEN -1
      ELSE 0
    END;
  END IF;

  INSERT INTO public.creator_referrals (
    creator_id,
    referral_code,
    waitlist_signups,
    verified_signups,
    created_at,
    updated_at
  )
  VALUES (
    matched_creator_id,
    referral,
    signup_delta,
    verified_delta,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
  )
  ON CONFLICT (referral_code) DO UPDATE SET
    creator_id = COALESCE(public.creator_referrals.creator_id, EXCLUDED.creator_id),
    waitlist_signups = GREATEST(0, public.creator_referrals.waitlist_signups + signup_delta),
    verified_signups = GREATEST(0, public.creator_referrals.verified_signups + verified_delta),
    updated_at = CURRENT_TIMESTAMP;

  IF matched_creator_id IS NOT NULL THEN
    UPDATE public.creators
    SET waitlist_signups = GREATEST(0, waitlist_signups + signup_delta),
        verified_signups = GREATEST(0, verified_signups + verified_delta),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = matched_creator_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS founding_application_creator_referral_insert ON public.founding_applications;
CREATE TRIGGER founding_application_creator_referral_insert
AFTER INSERT ON public.founding_applications
FOR EACH ROW
EXECUTE FUNCTION public.sync_creator_referral_from_founding_application();

DROP TRIGGER IF EXISTS founding_application_creator_referral_status ON public.founding_applications;
CREATE TRIGGER founding_application_creator_referral_status
AFTER UPDATE OF status ON public.founding_applications
FOR EACH ROW
EXECUTE FUNCTION public.sync_creator_referral_from_founding_application();

ALTER TABLE public.cities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creators ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_communications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.waitlist_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.city_status_logs ENABLE ROW LEVEL SECURITY;
