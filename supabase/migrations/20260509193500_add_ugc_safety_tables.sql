-- UGC safety tables for Apple Guideline 1.2 review
-- Reports and block events are queued for support@facemeet.app review.

CREATE TABLE IF NOT EXISTS public.user_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    reported_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    reason TEXT NOT NULL CHECK (
        reason IN (
            'Harassment or abuse',
            'Fake profile / catfish',
            'Sexual content / nudity',
            'Minor safety concern',
            'Scam or spam',
            'Other'
        )
    ),
    details TEXT,
    details_flagged BOOLEAN NOT NULL DEFAULT false,
    source TEXT NOT NULL DEFAULT 'profile',
    match_id UUID REFERENCES public.matches(id) ON DELETE SET NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (
        status IN ('pending', 'reviewing', 'resolved', 'dismissed')
    ),
    admin_email TEXT NOT NULL DEFAULT 'support@facemeet.app',
    review_due_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '24 hours'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.blocked_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    blocker_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    blocked_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    source TEXT NOT NULL DEFAULT 'profile',
    match_id UUID REFERENCES public.matches(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT blocked_users_not_self CHECK (blocker_user_id <> blocked_user_id),
    CONSTRAINT blocked_users_unique_pair UNIQUE (blocker_user_id, blocked_user_id)
);

CREATE TABLE IF NOT EXISTS public.moderation_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL CHECK (
        event_type IN ('user_report', 'user_block', 'content_filter_flag')
    ),
    priority TEXT NOT NULL DEFAULT 'normal' CHECK (
        priority IN ('normal', 'high')
    ),
    actor_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    target_user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
    report_id UUID REFERENCES public.user_reports(id) ON DELETE SET NULL,
    blocked_user_id UUID REFERENCES public.blocked_users(id) ON DELETE SET NULL,
    source TEXT NOT NULL DEFAULT 'profile',
    match_id UUID REFERENCES public.matches(id) ON DELETE SET NULL,
    details JSONB NOT NULL DEFAULT '{}'::JSONB,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (
        status IN ('pending', 'reviewing', 'resolved', 'dismissed')
    ),
    admin_email TEXT NOT NULL DEFAULT 'support@facemeet.app',
    review_due_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '24 hours'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_user_reports_reporter
    ON public.user_reports(reporter_user_id);
CREATE INDEX IF NOT EXISTS idx_user_reports_reported_status
    ON public.user_reports(reported_user_id, status);
CREATE INDEX IF NOT EXISTS idx_user_reports_created_at
    ON public.user_reports(created_at);

CREATE INDEX IF NOT EXISTS idx_blocked_users_blocker
    ON public.blocked_users(blocker_user_id);
CREATE INDEX IF NOT EXISTS idx_blocked_users_blocked
    ON public.blocked_users(blocked_user_id);

CREATE INDEX IF NOT EXISTS idx_moderation_events_status_priority
    ON public.moderation_events(status, priority, created_at);
CREATE INDEX IF NOT EXISTS idx_moderation_events_actor
    ON public.moderation_events(actor_user_id);
CREATE INDEX IF NOT EXISTS idx_moderation_events_target
    ON public.moderation_events(target_user_id);

ALTER TABLE public.user_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blocked_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_insert_own_reports" ON public.user_reports;
CREATE POLICY "users_insert_own_reports"
ON public.user_reports
FOR INSERT
TO authenticated
WITH CHECK (
    reporter_user_id = auth.uid()
    AND reported_user_id <> auth.uid()
);

DROP POLICY IF EXISTS "users_read_own_reports" ON public.user_reports;
CREATE POLICY "users_read_own_reports"
ON public.user_reports
FOR SELECT
TO authenticated
USING (reporter_user_id = auth.uid());

DROP POLICY IF EXISTS "users_insert_own_blocks" ON public.blocked_users;
CREATE POLICY "users_insert_own_blocks"
ON public.blocked_users
FOR INSERT
TO authenticated
WITH CHECK (
    blocker_user_id = auth.uid()
    AND blocked_user_id <> auth.uid()
);

DROP POLICY IF EXISTS "users_read_relevant_blocks" ON public.blocked_users;
CREATE POLICY "users_read_relevant_blocks"
ON public.blocked_users
FOR SELECT
TO authenticated
USING (
    blocker_user_id = auth.uid()
    OR blocked_user_id = auth.uid()
);

DROP POLICY IF EXISTS "users_delete_own_blocks" ON public.blocked_users;
CREATE POLICY "users_delete_own_blocks"
ON public.blocked_users
FOR DELETE
TO authenticated
USING (blocker_user_id = auth.uid());

DROP POLICY IF EXISTS "users_insert_own_moderation_events" ON public.moderation_events;
CREATE POLICY "users_insert_own_moderation_events"
ON public.moderation_events
FOR INSERT
TO authenticated
WITH CHECK (actor_user_id = auth.uid());
