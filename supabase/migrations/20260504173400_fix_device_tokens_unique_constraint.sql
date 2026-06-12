-- Fix device_tokens: add unique constraint on (user_id, fcm_token) so upsert works correctly.
-- The Dart code calls .upsert(..., onConflict: 'user_id,fcm_token') which requires a
-- unique index on that column pair. Without it the upsert throws a PostgreSQL error and
-- the FCM token is never saved, breaking iOS (and Android) push notifications.

-- Also add a unique constraint on (user_id, platform) so each user has at most one token
-- per platform (prevents duplicate rows accumulating over time).

-- Step 1: Remove any duplicate rows before adding the unique index.
-- Keep the most recently updated row for each (user_id, fcm_token) pair.
DELETE FROM public.device_tokens
WHERE id NOT IN (
    SELECT DISTINCT ON (user_id, fcm_token) id
    FROM public.device_tokens
    ORDER BY user_id, fcm_token, updated_at DESC NULLS LAST
);

-- Step 2: Add unique index on (user_id, fcm_token) — required for upsert onConflict.
CREATE UNIQUE INDEX IF NOT EXISTS idx_device_tokens_user_fcm
    ON public.device_tokens (user_id, fcm_token);

-- Step 3: Ensure RLS is enabled.
ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

-- Step 4: Ensure authenticated users can manage their own tokens.
DROP POLICY IF EXISTS "users_manage_own_device_tokens" ON public.device_tokens;
CREATE POLICY "users_manage_own_device_tokens"
    ON public.device_tokens
    FOR ALL
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
