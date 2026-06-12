-- FaceMeet Referral System Migration
-- Adds username, referral_code, referred_by, and spark_balance columns to users table

-- Add username column (unique, nullable initially)
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS username TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS referral_code TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS referred_by TEXT,
  ADD COLUMN IF NOT EXISTS spark_balance INTEGER DEFAULT 0 NOT NULL;

-- Index for fast referral code lookups
CREATE INDEX IF NOT EXISTS idx_users_referral_code ON public.users(referral_code);
CREATE INDEX IF NOT EXISTS idx_users_referred_by ON public.users(referred_by);
CREATE INDEX IF NOT EXISTS idx_users_username ON public.users(username);

-- Function: generate a unique referral code for a user
CREATE OR REPLACE FUNCTION public.generate_referral_code(user_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code TEXT;
  v_exists BOOLEAN;
BEGIN
  LOOP
    -- Generate 8-char alphanumeric code from user_id + random suffix
    v_code := UPPER(SUBSTRING(REPLACE(user_id::TEXT, '-', ''), 1, 4) || SUBSTRING(MD5(RANDOM()::TEXT), 1, 4));
    SELECT EXISTS(SELECT 1 FROM public.users WHERE referral_code = v_code) INTO v_exists;
    EXIT WHEN NOT v_exists;
  END LOOP;
  RETURN v_code;
END;
$$;

-- Function: award referral sparks when a referred user joins
CREATE OR REPLACE FUNCTION public.award_referral_spark_on_join(p_referred_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_referred_by TEXT;
  v_referrer_id UUID;
BEGIN
  -- Get the referred_by code from the new user
  SELECT referred_by INTO v_referred_by
  FROM public.users
  WHERE id = p_referred_user_id;

  IF v_referred_by IS NULL OR v_referred_by = '' THEN
    RETURN;
  END IF;

  -- Find the referrer by their referral_code
  SELECT id INTO v_referrer_id
  FROM public.users
  WHERE referral_code = v_referred_by;

  IF v_referrer_id IS NULL THEN
    RETURN;
  END IF;

  -- Increment referrer's spark_balance by 1
  UPDATE public.users
  SET spark_balance = spark_balance + 1
  WHERE id = v_referrer_id;
END;
$$;

-- Function: award 3 bonus sparks when a referred user upgrades to Spark+
CREATE OR REPLACE FUNCTION public.award_referral_spark_on_upgrade(p_upgraded_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_referred_by TEXT;
  v_referrer_id UUID;
BEGIN
  SELECT referred_by INTO v_referred_by
  FROM public.users
  WHERE id = p_upgraded_user_id;

  IF v_referred_by IS NULL OR v_referred_by = '' THEN
    RETURN;
  END IF;

  SELECT id INTO v_referrer_id
  FROM public.users
  WHERE referral_code = v_referred_by;

  IF v_referrer_id IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.users
  SET spark_balance = spark_balance + 3
  WHERE id = v_referrer_id;
END;
$$;

-- Backfill: generate referral codes for existing users who don't have one
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN SELECT id FROM public.users WHERE referral_code IS NULL LOOP
    UPDATE public.users
    SET referral_code = public.generate_referral_code(r.id)
    WHERE id = r.id;
  END LOOP;
END;
$$;
