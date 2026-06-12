ALTER TABLE public.referral_attributions
  ALTER COLUMN reward_status SET DEFAULT 'pending';

UPDATE public.referral_attributions
SET reward_status = 'pending'
WHERE reward_status IS NULL OR trim(reward_status) = '';

ALTER TABLE public.referral_attributions
  ADD COLUMN IF NOT EXISTS reward_credited_at TIMESTAMPTZ NULL,
  ADD COLUMN IF NOT EXISTS error_message TEXT NULL;

CREATE OR REPLACE VIEW public.referral_attribution_details AS
SELECT
  ra.id AS referral_attribution_id,
  ra.referrer_id,
  referrer.username AS referrer_username,
  referrer.referral_code AS referrer_referral_code,
  ra.referred_user_id,
  referred.username AS referred_username,
  referred.referred_by,
  ra.referral_code AS referral_code_used,
  ra.reward_status,
  ra.reward_credited_at,
  ra.created_at
FROM public.referral_attributions ra
JOIN public.users referrer ON referrer.id = ra.referrer_id
JOIN public.users referred ON referred.id = ra.referred_user_id;
