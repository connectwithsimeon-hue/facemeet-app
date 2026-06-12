-- Add spark replenishment tracking column
-- spark_last_replenished_at: tracks when the last tier replenishment was applied
-- This enables the daily (Spark+/Gold) and weekly (Free) replenishment logic

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS spark_last_replenished_at TIMESTAMPTZ DEFAULT NULL;

-- Ensure spark_balance column exists with correct default
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS spark_balance INTEGER DEFAULT 3;

-- Set initial replenishment date for existing users who have never been replenished
UPDATE public.users
SET spark_last_replenished_at = CURRENT_TIMESTAMP
WHERE spark_last_replenished_at IS NULL;

-- Index for replenishment queries
CREATE INDEX IF NOT EXISTS idx_users_replenished_at
  ON public.users(spark_last_replenished_at, subscription_tier);
