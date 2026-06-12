-- Add video_prompt column to users table
ALTER TABLE public.users
ADD COLUMN IF NOT EXISTS video_prompt TEXT;
