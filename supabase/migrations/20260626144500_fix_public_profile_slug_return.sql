-- Add an explicit fallback return for the public profile slug generator.

CREATE OR REPLACE FUNCTION public.generate_public_profile_slug(
  p_user_id UUID,
  p_username TEXT,
  p_first_name TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_base TEXT := public.public_profile_slug_base(COALESCE(NULLIF(BTRIM(p_username), ''), NULLIF(BTRIM(p_first_name), '')));
  v_candidate TEXT;
  v_suffix TEXT;
  v_attempt INTEGER := 0;
BEGIN
  LOOP
    IF v_attempt = 0 THEN
      v_candidate := v_base;
    ELSE
      v_suffix := substring(replace(gen_random_uuid()::TEXT, '-', '') from 1 for 4);
      v_candidate := v_base || '-' || v_suffix;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.public_profile_slug = v_candidate
        AND u.id <> p_user_id
    ) THEN
      RETURN v_candidate;
    END IF;

    v_attempt := v_attempt + 1;
    IF v_attempt > 30 THEN
      RETURN 'facemeet-' || substring(replace(gen_random_uuid()::TEXT, '-', '') from 1 for 8);
    END IF;
  END LOOP;

  RETURN 'facemeet-' || substring(replace(gen_random_uuid()::TEXT, '-', '') from 1 for 8);
END;
$$;
