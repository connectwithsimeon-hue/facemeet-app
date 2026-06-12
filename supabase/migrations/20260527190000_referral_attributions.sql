CREATE TABLE IF NOT EXISTS public.referral_attributions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  referred_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  referral_code TEXT NOT NULL,
  reward_status TEXT NOT NULL DEFAULT 'credited',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(referred_user_id)
);

CREATE INDEX IF NOT EXISTS idx_referral_attributions_referrer_id
  ON public.referral_attributions(referrer_id);

CREATE INDEX IF NOT EXISTS idx_referral_attributions_referral_code
  ON public.referral_attributions(referral_code);

ALTER TABLE public.referral_attributions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_read_own_referral_attributions"
ON public.referral_attributions;

CREATE POLICY "users_read_own_referral_attributions"
ON public.referral_attributions
FOR SELECT
TO authenticated
USING (referrer_id = auth.uid() OR referred_user_id = auth.uid());
