-- Web/PWA Stripe payment foundation.
-- Safe/idempotent migration: creates missing payment tracking and adds
-- user fields required by Stripe webhooks.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS stripe_customer_id TEXT,
  ADD COLUMN IF NOT EXISTS subscription_tier TEXT NOT NULL DEFAULT 'free',
  ADD COLUMN IF NOT EXISTS subscription_expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS spark_balance INTEGER NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS spark_last_replenished_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS public.payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  stripe_payment_intent_id TEXT,
  stripe_customer_id TEXT,
  product_type TEXT NOT NULL,
  amount_cents INTEGER,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payments_user_id
  ON public.payments(user_id);

CREATE INDEX IF NOT EXISTS idx_payments_stripe_customer_id
  ON public.payments(stripe_customer_id);

CREATE INDEX IF NOT EXISTS idx_payments_product_type
  ON public.payments(product_type);

CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_stripe_payment_intent_id
  ON public.payments(stripe_payment_intent_id)
  WHERE stripe_payment_intent_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_users_stripe_customer_id
  ON public.users(stripe_customer_id)
  WHERE stripe_customer_id IS NOT NULL;

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_read_own_payments" ON public.payments;
CREATE POLICY "users_read_own_payments"
ON public.payments
FOR SELECT
TO authenticated
USING (user_id = auth.uid());
