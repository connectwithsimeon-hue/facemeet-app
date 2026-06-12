-- Add weekly spark tracking columns for free users
ALTER TABLE users ADD COLUMN IF NOT EXISTS sparks_used_this_week integer default 0;
ALTER TABLE users ADD COLUMN IF NOT EXISTS sparks_week_reset_date date default current_date;
