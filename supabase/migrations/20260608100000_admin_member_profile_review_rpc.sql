CREATE OR REPLACE FUNCTION public.admin_get_member_profile(
  p_user_id UUID
)
RETURNS TABLE (
  id UUID,
  email TEXT,
  first_name TEXT,
  age INTEGER,
  gender public.gender_type,
  interested_in public.interested_in_type,
  city TEXT,
  state_region TEXT,
  country TEXT,
  metro_area TEXT,
  bio TEXT,
  interests TEXT[],
  profile_video_url TEXT,
  thumbnail_url TEXT,
  video_prompt TEXT,
  video_upload_count INTEGER,
  onboarding_complete BOOLEAN,
  verification_status public.verification_status_type,
  is_verified BOOLEAN,
  moderation_status TEXT,
  moderation_reason TEXT,
  moderated_at TIMESTAMPTZ,
  last_active TIMESTAMPTZ,
  created_at TIMESTAMPTZ,
  has_profile_video BOOLEAN,
  is_profile_complete BOOLEAN,
  is_effectively_verified BOOLEAN,
  missing_required_fields JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(NULL) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  RETURN QUERY
  WITH target_user AS (
    SELECT
      u.id,
      u.email,
      u.first_name,
      u.age,
      u.gender,
      u.interested_in,
      u.city,
      u.state_region,
      u.country,
      u.metro_area,
      u.bio,
      u.interests,
      u.profile_video_url,
      u.thumbnail_url,
      u.video_prompt,
      u.video_upload_count,
      u.onboarding_complete,
      u.verification_status,
      COALESCE(u.is_verified, false) AS is_verified,
      u.moderation_status,
      u.moderation_reason,
      u.moderated_at,
      u.last_active,
      u.created_at,
      COALESCE(NULLIF(BTRIM(u.first_name), ''), '') <> '' AS has_first_name,
      COALESCE(u.age, 0) >= 18 AS has_valid_age,
      u.gender IS NOT NULL AS has_gender,
      u.interested_in IS NOT NULL AS has_interested_in,
      COALESCE(cardinality(u.interests), 0) >= 3 AS has_minimum_interests,
      COALESCE(NULLIF(BTRIM(u.city), ''), '') <> '' AS has_city,
      COALESCE(NULLIF(BTRIM(u.state_region), ''), '') <> '' AS has_state_region,
      COALESCE(NULLIF(BTRIM(u.country), ''), '') <> '' AS has_country,
      COALESCE(NULLIF(BTRIM(u.profile_video_url), ''), '') <> '' AS has_profile_video
    FROM public.users u
    WHERE u.id = p_user_id
  )
  SELECT
    tu.id,
    tu.email,
    tu.first_name,
    tu.age,
    tu.gender,
    tu.interested_in,
    tu.city,
    tu.state_region,
    tu.country,
    tu.metro_area,
    tu.bio,
    tu.interests,
    tu.profile_video_url,
    tu.thumbnail_url,
    tu.video_prompt,
    tu.video_upload_count,
    tu.onboarding_complete,
    tu.verification_status,
    tu.is_verified,
    tu.moderation_status,
    tu.moderation_reason,
    tu.moderated_at,
    tu.last_active,
    tu.created_at,
    tu.has_profile_video,
    (
      tu.has_first_name
      AND tu.has_valid_age
      AND tu.has_gender
      AND tu.has_interested_in
      AND tu.has_minimum_interests
      AND tu.has_city
      AND tu.has_state_region
      AND tu.has_country
      AND tu.has_profile_video
      AND COALESCE(tu.onboarding_complete, false)
    ) AS is_profile_complete,
    (
      tu.verification_status = 'verified'
      OR tu.is_verified = true
    ) AS is_effectively_verified,
    (
      SELECT COALESCE(
        jsonb_agg(label ORDER BY sort_order),
        '[]'::JSONB
      )
      FROM (
        SELECT 1 AS sort_order, 'First name' AS label WHERE NOT tu.has_first_name
        UNION ALL
        SELECT 2, 'Age' WHERE NOT tu.has_valid_age
        UNION ALL
        SELECT 3, 'Gender' WHERE NOT tu.has_gender
        UNION ALL
        SELECT 4, 'Interested in' WHERE NOT tu.has_interested_in
        UNION ALL
        SELECT 5, 'At least 3 interests' WHERE NOT tu.has_minimum_interests
        UNION ALL
        SELECT 6, 'City' WHERE NOT tu.has_city
        UNION ALL
        SELECT 7, 'State / Region' WHERE NOT tu.has_state_region
        UNION ALL
        SELECT 8, 'Country' WHERE NOT tu.has_country
        UNION ALL
        SELECT 9, 'Profile video' WHERE NOT tu.has_profile_video
        UNION ALL
        SELECT 10, 'Onboarding completion' WHERE NOT COALESCE(tu.onboarding_complete, false)
      ) AS missing
    ) AS missing_required_fields
  FROM target_user tu;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_member_profile(UUID) TO authenticated;
