-- Add thumbnail_url column to store static JPEG thumbnail from profile video
ALTER TABLE users ADD COLUMN IF NOT EXISTS thumbnail_url text;
