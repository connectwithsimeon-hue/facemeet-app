-- FaceMeet Initial Schema Migration
-- Tables: users (profiles), interactions, matches, spark_sessions, messages

-- ============================================================
-- 1. ENUMS
-- ============================================================
DROP TYPE IF EXISTS public.gender_type CASCADE;
CREATE TYPE public.gender_type AS ENUM ('man', 'woman', 'non_binary', 'other');

DROP TYPE IF EXISTS public.interested_in_type CASCADE;
CREATE TYPE public.interested_in_type AS ENUM ('men', 'women', 'everyone');

DROP TYPE IF EXISTS public.verification_status_type CASCADE;
CREATE TYPE public.verification_status_type AS ENUM ('pending', 'verified');

DROP TYPE IF EXISTS public.interaction_action_type CASCADE;
CREATE TYPE public.interaction_action_type AS ENUM ('spark', 'skip');

DROP TYPE IF EXISTS public.match_status_type CASCADE;
CREATE TYPE public.match_status_type AS ENUM ('matched_pending_session', 'session_complete', 'chat_unlocked', 'session_ended');

DROP TYPE IF EXISTS public.session_outcome_type CASCADE;
CREATE TYPE public.session_outcome_type AS ENUM ('mutual_spark', 'no_spark');

-- ============================================================
-- 2. CORE TABLES
-- ============================================================

-- Users (profiles) table
CREATE TABLE IF NOT EXISTS public.users (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT NOT NULL UNIQUE,
    first_name TEXT,
    age INTEGER,
    gender public.gender_type,
    interested_in public.interested_in_type,
    city TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    bio TEXT,
    interests TEXT[] DEFAULT ARRAY[]::TEXT[],
    profile_video_url TEXT,
    verification_status public.verification_status_type DEFAULT 'pending'::public.verification_status_type,
    onboarding_complete BOOLEAN DEFAULT false,
    last_active TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Interactions table
CREATE TABLE IF NOT EXISTS public.interactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    to_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    action_type public.interaction_action_type NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Matches table
CREATE TABLE IF NOT EXISTS public.matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_1_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    user_2_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    status public.match_status_type DEFAULT 'matched_pending_session'::public.match_status_type,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Spark sessions table
CREATE TABLE IF NOT EXISTS public.spark_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
    daily_room_url TEXT,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    decision_user_1 public.interaction_action_type,
    decision_user_2 public.interaction_action_type,
    outcome public.session_outcome_type,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Messages table
CREATE TABLE IF NOT EXISTS public.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id UUID NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
    sender_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    is_read BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- 3. INDEXES
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_users_onboarding ON public.users(onboarding_complete);
CREATE INDEX IF NOT EXISTS idx_users_last_active ON public.users(last_active);
CREATE INDEX IF NOT EXISTS idx_interactions_from_user ON public.interactions(from_user_id);
CREATE INDEX IF NOT EXISTS idx_interactions_to_user ON public.interactions(to_user_id);
CREATE INDEX IF NOT EXISTS idx_matches_user1 ON public.matches(user_1_id);
CREATE INDEX IF NOT EXISTS idx_matches_user2 ON public.matches(user_2_id);
CREATE INDEX IF NOT EXISTS idx_spark_sessions_match ON public.spark_sessions(match_id);
CREATE INDEX IF NOT EXISTS idx_messages_match ON public.messages(match_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON public.messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_created ON public.messages(created_at);

-- ============================================================
-- 4. FUNCTIONS (must be before RLS policies)
-- ============================================================

-- Auto-create user profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO public.users (id, email, first_name)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'first_name', '')
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

-- Check if two users have mutually sparked each other
CREATE OR REPLACE FUNCTION public.check_mutual_spark(p_user1 UUID, p_user2 UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
SELECT EXISTS (
    SELECT 1 FROM public.interactions i1
    JOIN public.interactions i2
        ON i1.from_user_id = p_user2 AND i1.to_user_id = p_user1
    WHERE i1.action_type = 'spark'
      AND i2.from_user_id = p_user1 AND i2.to_user_id = p_user2
      AND i2.action_type = 'spark'
);
$$;

-- ============================================================
-- 5. ENABLE RLS
-- ============================================================
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.interactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.spark_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 6. RLS POLICIES
-- ============================================================

-- users: own profile management
DROP POLICY IF EXISTS "users_manage_own_profile" ON public.users;
CREATE POLICY "users_manage_own_profile"
ON public.users
FOR ALL
TO authenticated
USING (id = auth.uid())
WITH CHECK (id = auth.uid());

-- users: discovery feed - read all completed profiles (excluding self)
DROP POLICY IF EXISTS "users_read_completed_profiles" ON public.users;
CREATE POLICY "users_read_completed_profiles"
ON public.users
FOR SELECT
TO authenticated
USING (onboarding_complete = true AND id != auth.uid());

-- interactions: users manage their own interactions
DROP POLICY IF EXISTS "users_manage_own_interactions" ON public.interactions;
CREATE POLICY "users_manage_own_interactions"
ON public.interactions
FOR ALL
TO authenticated
USING (from_user_id = auth.uid())
WITH CHECK (from_user_id = auth.uid());

-- interactions: users can read interactions directed at them
DROP POLICY IF EXISTS "users_read_received_interactions" ON public.interactions;
CREATE POLICY "users_read_received_interactions"
ON public.interactions
FOR SELECT
TO authenticated
USING (to_user_id = auth.uid());

-- matches: users can read their own matches
DROP POLICY IF EXISTS "users_read_own_matches" ON public.matches;
CREATE POLICY "users_read_own_matches"
ON public.matches
FOR SELECT
TO authenticated
USING (user_1_id = auth.uid() OR user_2_id = auth.uid());

-- matches: users can insert matches (when mutual spark detected)
DROP POLICY IF EXISTS "users_insert_matches" ON public.matches;
CREATE POLICY "users_insert_matches"
ON public.matches
FOR INSERT
TO authenticated
WITH CHECK (user_1_id = auth.uid() OR user_2_id = auth.uid());

-- matches: users can update their own matches
DROP POLICY IF EXISTS "users_update_own_matches" ON public.matches;
CREATE POLICY "users_update_own_matches"
ON public.matches
FOR UPDATE
TO authenticated
USING (user_1_id = auth.uid() OR user_2_id = auth.uid())
WITH CHECK (user_1_id = auth.uid() OR user_2_id = auth.uid());

-- spark_sessions: users can read sessions for their matches
DROP POLICY IF EXISTS "users_read_own_spark_sessions" ON public.spark_sessions;
CREATE POLICY "users_read_own_spark_sessions"
ON public.spark_sessions
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.matches m
        WHERE m.id = spark_sessions.match_id
          AND (m.user_1_id = auth.uid() OR m.user_2_id = auth.uid())
    )
);

-- spark_sessions: users can insert/update sessions for their matches
DROP POLICY IF EXISTS "users_manage_own_spark_sessions" ON public.spark_sessions;
CREATE POLICY "users_manage_own_spark_sessions"
ON public.spark_sessions
FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.matches m
        WHERE m.id = spark_sessions.match_id
          AND (m.user_1_id = auth.uid() OR m.user_2_id = auth.uid())
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.matches m
        WHERE m.id = spark_sessions.match_id
          AND (m.user_1_id = auth.uid() OR m.user_2_id = auth.uid())
    )
);

-- messages: users can read messages in their unlocked matches
DROP POLICY IF EXISTS "users_read_own_messages" ON public.messages;
CREATE POLICY "users_read_own_messages"
ON public.messages
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.matches m
        WHERE m.id = messages.match_id
          AND (m.user_1_id = auth.uid() OR m.user_2_id = auth.uid())
          AND m.status = 'chat_unlocked'
    )
);

-- messages: users can send messages in their unlocked matches
DROP POLICY IF EXISTS "users_send_messages" ON public.messages;
CREATE POLICY "users_send_messages"
ON public.messages
FOR INSERT
TO authenticated
WITH CHECK (
    sender_id = auth.uid()
    AND EXISTS (
        SELECT 1 FROM public.matches m
        WHERE m.id = messages.match_id
          AND (m.user_1_id = auth.uid() OR m.user_2_id = auth.uid())
          AND m.status = 'chat_unlocked'
    )
);

-- messages: users can update (mark as read) messages in their matches
DROP POLICY IF EXISTS "users_update_messages" ON public.messages;
CREATE POLICY "users_update_messages"
ON public.messages
FOR UPDATE
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.matches m
        WHERE m.id = messages.match_id
          AND (m.user_1_id = auth.uid() OR m.user_2_id = auth.uid())
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.matches m
        WHERE m.id = messages.match_id
          AND (m.user_1_id = auth.uid() OR m.user_2_id = auth.uid())
    )
);

-- ============================================================
-- 7. TRIGGERS
-- ============================================================
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();

-- ============================================================
-- 8. MOCK DATA
-- ============================================================
DO $$
DECLARE
    demo_uuid UUID := gen_random_uuid();
    user2_uuid UUID := gen_random_uuid();
BEGIN
    -- Demo user 1: demo@facemeet.app / Spark$2026
    INSERT INTO auth.users (
        id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
        created_at, updated_at, raw_user_meta_data, raw_app_meta_data,
        is_sso_user, is_anonymous, confirmation_token, confirmation_sent_at,
        recovery_token, recovery_sent_at, email_change_token_new, email_change,
        email_change_sent_at, email_change_token_current, email_change_confirm_status,
        reauthentication_token, reauthentication_sent_at, phone, phone_change,
        phone_change_token, phone_change_sent_at
    ) VALUES (
        demo_uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'demo@facemeet.app', crypt('Spark$2026', gen_salt('bf', 10)), now(), now(), now(),
        jsonb_build_object('first_name', 'Alex'),
        jsonb_build_object('provider', 'email', 'providers', ARRAY['email']::TEXT[]),
        false, false, '', null, '', null, '', '', null, '', 0, '', null, null, '', '', null
    ) ON CONFLICT (id) DO NOTHING;

    -- Demo user 2
    INSERT INTO auth.users (
        id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
        created_at, updated_at, raw_user_meta_data, raw_app_meta_data,
        is_sso_user, is_anonymous, confirmation_token, confirmation_sent_at,
        recovery_token, recovery_sent_at, email_change_token_new, email_change,
        email_change_sent_at, email_change_token_current, email_change_confirm_status,
        reauthentication_token, reauthentication_sent_at, phone, phone_change,
        phone_change_token, phone_change_sent_at
    ) VALUES (
        user2_uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'jamie@facemeet.app', crypt('Spark$2026', gen_salt('bf', 10)), now(), now(), now(),
        jsonb_build_object('first_name', 'Jamie'),
        jsonb_build_object('provider', 'email', 'providers', ARRAY['email']::TEXT[]),
        false, false, '', null, '', null, '', '', null, '', 0, '', null, null, '', '', null
    ) ON CONFLICT (id) DO NOTHING;

    -- Update demo user profiles (trigger creates the row, we update with full data)
    UPDATE public.users SET
        first_name = 'Alex',
        age = 28,
        gender = 'man'::public.gender_type,
        interested_in = 'women'::public.interested_in_type,
        city = 'New York',
        bio = 'Love hiking, coffee, and real conversations.',
        interests = ARRAY['hiking', 'coffee', 'travel', 'photography'],
        verification_status = 'verified'::public.verification_status_type,
        onboarding_complete = true,
        last_active = now()
    WHERE id = demo_uuid;

    UPDATE public.users SET
        first_name = 'Jamie',
        age = 26,
        gender = 'woman'::public.gender_type,
        interested_in = 'men'::public.interested_in_type,
        city = 'Brooklyn',
        bio = 'Artist, bookworm, and adventure seeker.',
        interests = ARRAY['art', 'books', 'yoga', 'music'],
        verification_status = 'verified'::public.verification_status_type,
        onboarding_complete = true,
        last_active = now()
    WHERE id = user2_uuid;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Mock data insertion failed: %', SQLERRM;
END $$;
