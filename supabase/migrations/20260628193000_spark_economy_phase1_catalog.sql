-- Spark Economy Phase 1 catalog update.
-- Keep product IDs and prices unchanged while changing subscription Spark grants.

UPDATE public.payment_product_catalog
SET spark_amount = CASE product_id
    WHEN 'spark_plus_monthly' THEN 2
    WHEN 'gold_monthly' THEN 5
    ELSE spark_amount
  END,
  metadata = metadata || jsonb_build_object(
    'spark_economy_phase', 'phase_1_launch_safety',
    'daily_bonus_sparks', CASE product_id
      WHEN 'spark_plus_monthly' THEN 2
      WHEN 'gold_monthly' THEN 5
      ELSE spark_amount
    END
  ),
  updated_at = now()
WHERE platform = 'google_play'
  AND product_id IN ('spark_plus_monthly', 'gold_monthly');
