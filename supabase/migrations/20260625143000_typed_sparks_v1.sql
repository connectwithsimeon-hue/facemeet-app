-- Typed Sparks v1
-- Store connection context on Spark interactions without changing existing
-- match, chat unlock, or Spark Session behavior.

ALTER TABLE public.interactions
  ADD COLUMN IF NOT EXISTS spark_type TEXT;

UPDATE public.interactions
SET spark_type = 'dating'
WHERE action_type = 'spark'
  AND spark_type IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'interactions_spark_type_check'
      AND conrelid = 'public.interactions'::regclass
  ) THEN
    ALTER TABLE public.interactions
      ADD CONSTRAINT interactions_spark_type_check
      CHECK (
        spark_type IS NULL
        OR spark_type IN ('dating', 'friendship', 'professional', 'event')
      );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_interactions_spark_type
  ON public.interactions(spark_type)
  WHERE action_type = 'spark';
