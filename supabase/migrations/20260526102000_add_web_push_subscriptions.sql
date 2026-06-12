-- Web/PWA push subscriptions for installed FaceMeet PWAs.
-- Native iOS/Android FCM tokens remain in public.device_tokens.

CREATE TABLE IF NOT EXISTS public.web_push_subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    endpoint TEXT NOT NULL,
    p256dh TEXT NOT NULL,
    auth TEXT NOT NULL,
    user_agent TEXT,
    platform TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_web_push_subscriptions_endpoint
    ON public.web_push_subscriptions (endpoint);

CREATE INDEX IF NOT EXISTS idx_web_push_subscriptions_user_active
    ON public.web_push_subscriptions (user_id, is_active);

ALTER TABLE public.web_push_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_manage_own_web_push_subscriptions"
    ON public.web_push_subscriptions;
CREATE POLICY "users_manage_own_web_push_subscriptions"
    ON public.web_push_subscriptions
    FOR ALL
    TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());
