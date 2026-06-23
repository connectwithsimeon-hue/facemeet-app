-- Google Play purchase transaction recording and revenue ledger foundation.
-- Server-owned catalog and idempotent fulfillment for RevenueCat / Google Play.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS subscription_tier TEXT NOT NULL DEFAULT 'free',
  ADD COLUMN IF NOT EXISTS subscription_expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS spark_balance INTEGER NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS spark_last_replenished_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS public.payment_product_catalog (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  platform TEXT NOT NULL,
  product_id TEXT NOT NULL,
  product_type TEXT NOT NULL,
  display_name TEXT NOT NULL,
  currency TEXT NOT NULL DEFAULT 'USD',
  amount_cents INTEGER NOT NULL CHECK (amount_cents >= 0),
  spark_amount INTEGER NOT NULL DEFAULT 0 CHECK (spark_amount >= 0),
  subscription_tier TEXT,
  subscription_period TEXT,
  platform_fee_bps INTEGER NOT NULL DEFAULT 3000 CHECK (platform_fee_bps BETWEEN 0 AND 10000),
  processor_fee_cents INTEGER NOT NULL DEFAULT 0 CHECK (processor_fee_cents >= 0),
  spark_cost_cents INTEGER NOT NULL DEFAULT 0 CHECK (spark_cost_cents >= 0),
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (platform, product_id),
  CHECK (platform IN ('google_play', 'app_store', 'stripe')),
  CHECK (product_type IN ('spark_bundle', 'subscription'))
);

INSERT INTO public.payment_product_catalog (
  platform,
  product_id,
  product_type,
  display_name,
  currency,
  amount_cents,
  spark_amount,
  subscription_tier,
  subscription_period,
  platform_fee_bps,
  metadata
)
VALUES
  ('google_play', 'spark_bundle_3', 'spark_bundle', '3 Spark Bundle', 'USD', 499, 3, NULL, NULL, 3000, '{"source":"server_catalog"}'),
  ('google_play', 'spark_bundle_10', 'spark_bundle', '10 Spark Bundle', 'USD', 1299, 10, NULL, NULL, 3000, '{"source":"server_catalog"}'),
  ('google_play', 'spark_bundle_25', 'spark_bundle', '25 Spark Bundle', 'USD', 2499, 25, NULL, NULL, 3000, '{"source":"server_catalog"}'),
  ('google_play', 'spark_plus_monthly', 'subscription', 'Spark+ Monthly', 'USD', 1499, 3, 'spark_plus', 'month', 3000, '{"source":"server_catalog"}'),
  ('google_play', 'gold_monthly', 'subscription', 'Gold Monthly', 'USD', 2999, 10, 'gold', 'month', 3000, '{"source":"server_catalog"}')
ON CONFLICT (platform, product_id) DO UPDATE SET
  product_type = EXCLUDED.product_type,
  display_name = EXCLUDED.display_name,
  currency = EXCLUDED.currency,
  amount_cents = EXCLUDED.amount_cents,
  spark_amount = EXCLUDED.spark_amount,
  subscription_tier = EXCLUDED.subscription_tier,
  subscription_period = EXCLUDED.subscription_period,
  platform_fee_bps = EXCLUDED.platform_fee_bps,
  enabled = TRUE,
  metadata = public.payment_product_catalog.metadata || EXCLUDED.metadata,
  updated_at = now();

CREATE TABLE IF NOT EXISTS public.purchase_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  platform TEXT NOT NULL,
  provider TEXT NOT NULL DEFAULT 'revenuecat',
  provider_order_id TEXT,
  provider_purchase_token_hash TEXT,
  provider_purchase_token_last4 TEXT,
  store_product_id TEXT,
  product_id TEXT NOT NULL,
  product_type TEXT NOT NULL,
  currency TEXT NOT NULL DEFAULT 'USD',
  gross_amount_cents INTEGER NOT NULL DEFAULT 0 CHECK (gross_amount_cents >= 0),
  platform_fee_cents INTEGER NOT NULL DEFAULT 0 CHECK (platform_fee_cents >= 0),
  processor_fee_cents INTEGER NOT NULL DEFAULT 0 CHECK (processor_fee_cents >= 0),
  spark_cost_cents INTEGER NOT NULL DEFAULT 0 CHECK (spark_cost_cents >= 0),
  refund_amount_cents INTEGER NOT NULL DEFAULT 0 CHECK (refund_amount_cents >= 0),
  net_revenue_cents INTEGER GENERATED ALWAYS AS (
    gross_amount_cents - platform_fee_cents - processor_fee_cents - spark_cost_cents - refund_amount_cents
  ) STORED,
  spark_amount INTEGER NOT NULL DEFAULT 0 CHECK (spark_amount >= 0),
  subscription_tier TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  verification_status TEXT NOT NULL DEFAULT 'client_confirmed',
  purchased_at TIMESTAMPTZ,
  verified_at TIMESTAMPTZ,
  fulfilled_at TIMESTAMPTZ,
  refunded_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (platform IN ('google_play', 'app_store', 'stripe')),
  CHECK (product_type IN ('spark_bundle', 'subscription')),
  CHECK (status IN ('pending', 'client_confirmed', 'verified', 'fulfilled', 'refunded', 'cancelled', 'failed')),
  CHECK (verification_status IN ('client_confirmed', 'verified', 'verification_unavailable', 'failed'))
);

CREATE INDEX IF NOT EXISTS idx_purchase_transactions_user_created
  ON public.purchase_transactions(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_purchase_transactions_status
  ON public.purchase_transactions(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_purchase_transactions_product
  ON public.purchase_transactions(platform, product_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_purchase_transactions_provider_order
  ON public.purchase_transactions(platform, provider_order_id)
  WHERE provider_order_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_purchase_transactions_token_hash
  ON public.purchase_transactions(platform, provider_purchase_token_hash)
  WHERE provider_purchase_token_hash IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.country_revenue_ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_transaction_id UUID NOT NULL UNIQUE REFERENCES public.purchase_transactions(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  country_code TEXT,
  country_source TEXT NOT NULL DEFAULT 'user_profile',
  currency TEXT NOT NULL DEFAULT 'USD',
  gross_amount_cents INTEGER NOT NULL DEFAULT 0,
  platform_fee_cents INTEGER NOT NULL DEFAULT 0,
  processor_fee_cents INTEGER NOT NULL DEFAULT 0,
  spark_cost_cents INTEGER NOT NULL DEFAULT 0,
  refund_amount_cents INTEGER NOT NULL DEFAULT 0,
  net_revenue_cents INTEGER NOT NULL DEFAULT 0,
  entry_type TEXT NOT NULL DEFAULT 'purchase',
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (entry_type IN ('purchase', 'refund', 'adjustment'))
);

CREATE INDEX IF NOT EXISTS idx_country_revenue_ledger_country_created
  ON public.country_revenue_ledger(country_code, created_at DESC);

CREATE TABLE IF NOT EXISTS public.partner_revenue_ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_transaction_id UUID NOT NULL UNIQUE REFERENCES public.purchase_transactions(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  partner_user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  referral_code TEXT,
  currency TEXT NOT NULL DEFAULT 'USD',
  gross_amount_cents INTEGER NOT NULL DEFAULT 0,
  net_revenue_cents INTEGER NOT NULL DEFAULT 0,
  commission_basis_cents INTEGER NOT NULL DEFAULT 0,
  commission_bps INTEGER NOT NULL DEFAULT 0,
  commission_amount_cents INTEGER NOT NULL DEFAULT 0,
  payout_status TEXT NOT NULL DEFAULT 'not_payable',
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (payout_status IN ('not_payable', 'pending_review', 'payable', 'paid', 'void'))
);

CREATE INDEX IF NOT EXISTS idx_partner_revenue_ledger_partner_created
  ON public.partner_revenue_ledger(partner_user_id, created_at DESC);

ALTER TABLE public.payment_product_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.country_revenue_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_revenue_ledger ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admins_read_payment_product_catalog" ON public.payment_product_catalog;
CREATE POLICY "admins_read_payment_product_catalog"
ON public.payment_product_catalog
FOR SELECT
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'support_staff']));

DROP POLICY IF EXISTS "users_read_own_purchase_transactions" ON public.purchase_transactions;
CREATE POLICY "users_read_own_purchase_transactions"
ON public.purchase_transactions
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "admins_read_purchase_transactions" ON public.purchase_transactions;
CREATE POLICY "admins_read_purchase_transactions"
ON public.purchase_transactions
FOR SELECT
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'support_staff']));

DROP POLICY IF EXISTS "admins_read_country_revenue_ledger" ON public.country_revenue_ledger;
CREATE POLICY "admins_read_country_revenue_ledger"
ON public.country_revenue_ledger
FOR SELECT
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'support_staff']));

DROP POLICY IF EXISTS "admins_read_partner_revenue_ledger" ON public.partner_revenue_ledger;
CREATE POLICY "admins_read_partner_revenue_ledger"
ON public.partner_revenue_ledger
FOR SELECT
TO authenticated
USING (public.has_admin_role(ARRAY['super_admin', 'support_staff']));

CREATE OR REPLACE FUNCTION public.record_google_play_purchase(
  p_product_id TEXT,
  p_provider_order_id TEXT DEFAULT NULL,
  p_provider_purchase_token TEXT DEFAULT NULL,
  p_store_product_id TEXT DEFAULT NULL,
  p_purchased_at TIMESTAMPTZ DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_catalog public.payment_product_catalog%ROWTYPE;
  v_existing public.purchase_transactions%ROWTYPE;
  v_transaction public.purchase_transactions%ROWTYPE;
  v_order_id TEXT := NULLIF(btrim(COALESCE(p_provider_order_id, '')), '');
  v_token TEXT := NULLIF(btrim(COALESCE(p_provider_purchase_token, '')), '');
  v_token_hash TEXT;
  v_token_last4 TEXT;
  v_platform_fee_cents INTEGER;
  v_current_balance INTEGER := 0;
  v_new_balance INTEGER := 0;
  v_country_code TEXT;
  v_partner_user_id UUID;
  v_referral_code TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  IF NULLIF(btrim(COALESCE(p_product_id, '')), '') IS NULL THEN
    RAISE EXCEPTION 'product_id is required';
  END IF;

  IF v_token IS NOT NULL THEN
    v_token_hash := encode(digest(v_token, 'sha256'), 'hex');
    v_token_last4 := right(v_token, 4);
  END IF;

  IF v_order_id IS NULL AND v_token_hash IS NULL THEN
    RAISE EXCEPTION 'provider order id or purchase token is required for idempotency';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('google_play_purchase:' || COALESCE(v_order_id, v_token_hash)));

  SELECT *
  INTO v_catalog
  FROM public.payment_product_catalog
  WHERE platform = 'google_play'
    AND enabled = TRUE
    AND product_id IN (
      btrim(p_product_id),
      NULLIF(btrim(COALESCE(p_store_product_id, '')), '')
    )
  ORDER BY CASE WHEN product_id = btrim(p_product_id) THEN 0 ELSE 1 END
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'unsupported Google Play product';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.purchase_transactions
  WHERE platform = 'google_play'
    AND (
      (v_order_id IS NOT NULL AND provider_order_id = v_order_id)
      OR (v_token_hash IS NOT NULL AND provider_purchase_token_hash = v_token_hash)
    )
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing.user_id <> v_user_id THEN
      RAISE EXCEPTION 'purchase transaction already belongs to another user';
    END IF;

    SELECT COALESCE(spark_balance, 0), COALESCE(country_code, canonical_country, country)
    INTO v_new_balance, v_country_code
    FROM public.users
    WHERE id = v_user_id;

    RETURN jsonb_build_object(
      'success', TRUE,
      'duplicate', TRUE,
      'transaction_id', v_existing.id,
      'status', v_existing.status,
      'spark_balance', v_new_balance,
      'product_id', v_existing.product_id
    );
  END IF;

  v_platform_fee_cents := floor(v_catalog.amount_cents * v_catalog.platform_fee_bps / 10000.0)::INTEGER;

  INSERT INTO public.purchase_transactions (
    user_id,
    platform,
    provider,
    provider_order_id,
    provider_purchase_token_hash,
    provider_purchase_token_last4,
    store_product_id,
    product_id,
    product_type,
    currency,
    gross_amount_cents,
    platform_fee_cents,
    processor_fee_cents,
    spark_cost_cents,
    spark_amount,
    subscription_tier,
    status,
    verification_status,
    purchased_at,
    metadata
  )
  VALUES (
    v_user_id,
    'google_play',
    'revenuecat',
    v_order_id,
    v_token_hash,
    v_token_last4,
    NULLIF(btrim(COALESCE(p_store_product_id, '')), ''),
    v_catalog.product_id,
    v_catalog.product_type,
    v_catalog.currency,
    v_catalog.amount_cents,
    v_platform_fee_cents,
    v_catalog.processor_fee_cents,
    v_catalog.spark_cost_cents,
    v_catalog.spark_amount,
    v_catalog.subscription_tier,
    'client_confirmed',
    'client_confirmed',
    COALESCE(p_purchased_at, now()),
    COALESCE(p_metadata, '{}'::JSONB) || jsonb_build_object(
      'verification_note', 'RevenueCat client confirmation recorded; raw Google Play token not stored in plaintext.'
    )
  )
  RETURNING * INTO v_transaction;

  SELECT COALESCE(spark_balance, 0), COALESCE(country_code, canonical_country, country)
  INTO v_current_balance, v_country_code
  FROM public.users
  WHERE id = v_user_id
  FOR UPDATE;

  IF v_catalog.product_type = 'spark_bundle' THEN
    v_new_balance := v_current_balance + v_catalog.spark_amount;

    UPDATE public.users
    SET spark_balance = v_new_balance
    WHERE id = v_user_id;
  ELSE
    v_new_balance := CASE
      WHEN v_current_balance >= 50 THEN v_current_balance
      ELSE LEAST(50, v_current_balance + v_catalog.spark_amount)
    END;

    UPDATE public.users
    SET subscription_tier = v_catalog.subscription_tier,
        subscription_expires_at = now() + interval '30 days',
        spark_balance = v_new_balance,
        spark_last_replenished_at = now()
    WHERE id = v_user_id;
  END IF;

  UPDATE public.purchase_transactions
  SET status = 'fulfilled',
      fulfilled_at = now(),
      updated_at = now()
  WHERE id = v_transaction.id
  RETURNING * INTO v_transaction;

  INSERT INTO public.country_revenue_ledger (
    purchase_transaction_id,
    user_id,
    country_code,
    currency,
    gross_amount_cents,
    platform_fee_cents,
    processor_fee_cents,
    spark_cost_cents,
    refund_amount_cents,
    net_revenue_cents,
    metadata
  )
  VALUES (
    v_transaction.id,
    v_user_id,
    v_country_code,
    v_transaction.currency,
    v_transaction.gross_amount_cents,
    v_transaction.platform_fee_cents,
    v_transaction.processor_fee_cents,
    v_transaction.spark_cost_cents,
    v_transaction.refund_amount_cents,
    v_transaction.net_revenue_cents,
    jsonb_build_object('product_id', v_transaction.product_id)
  )
  ON CONFLICT (purchase_transaction_id) DO NOTHING;

  SELECT ra.referrer_id, ra.referral_code
  INTO v_partner_user_id, v_referral_code
  FROM public.referral_attributions ra
  WHERE ra.referred_user_id = v_user_id
  LIMIT 1;

  IF v_partner_user_id IS NOT NULL THEN
    INSERT INTO public.partner_revenue_ledger (
      purchase_transaction_id,
      user_id,
      partner_user_id,
      referral_code,
      currency,
      gross_amount_cents,
      net_revenue_cents,
      commission_basis_cents,
      commission_bps,
      commission_amount_cents,
      payout_status,
      metadata
    )
    VALUES (
      v_transaction.id,
      v_user_id,
      v_partner_user_id,
      v_referral_code,
      v_transaction.currency,
      v_transaction.gross_amount_cents,
      v_transaction.net_revenue_cents,
      v_transaction.net_revenue_cents,
      0,
      0,
      'not_payable',
      jsonb_build_object('product_id', v_transaction.product_id, 'source', 'referral_attribution')
    )
    ON CONFLICT (purchase_transaction_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'duplicate', FALSE,
    'transaction_id', v_transaction.id,
    'status', v_transaction.status,
    'product_id', v_transaction.product_id,
    'spark_balance', v_new_balance,
    'subscription_tier', v_catalog.subscription_tier,
    'subscription_expires_at', CASE
      WHEN v_catalog.product_type = 'subscription' THEN (now() + interval '30 days')
      ELSE NULL
    END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_google_play_purchase(TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, JSONB)
TO authenticated;
