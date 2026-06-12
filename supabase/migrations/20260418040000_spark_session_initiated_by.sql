-- Migration: Add initiated_by column to spark_sessions for new spark requests from chat
-- Timestamp: 20260418040000

-- Add initiated_by column to spark_sessions to track who started the session
ALTER TABLE public.spark_sessions
ADD COLUMN IF NOT EXISTS initiated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL;

-- Add is_read column to messages if it doesn't exist
ALTER TABLE public.messages
ADD COLUMN IF NOT EXISTS is_read BOOLEAN NOT NULL DEFAULT false;

-- Index for faster unread message queries
CREATE INDEX IF NOT EXISTS idx_messages_match_id_is_read ON public.messages(match_id, is_read);
CREATE INDEX IF NOT EXISTS idx_spark_sessions_initiated_by ON public.spark_sessions(initiated_by);
