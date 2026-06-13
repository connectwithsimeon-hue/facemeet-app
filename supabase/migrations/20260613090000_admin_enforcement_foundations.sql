-- Admin enforcement foundations for processor readiness.
-- Adds reversible profile/account enforcement state, admin RPCs, and review visibility.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS profile_visibility_status TEXT NOT NULL DEFAULT 'visible',
  ADD COLUMN IF NOT EXISTS account_status TEXT NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS account_status_reason TEXT,
  ADD COLUMN IF NOT EXISTS account_status_updated_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS account_status_updated_by UUID REFERENCES public.admin_users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS profile_hidden_reason TEXT,
  ADD COLUMN IF NOT EXISTS profile_hidden_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS profile_hidden_by UUID REFERENCES public.admin_users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS profile_video_removed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS profile_video_removed_by UUID REFERENCES public.admin_users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS profile_video_removed_reason TEXT;

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_profile_visibility_status_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_profile_visibility_status_check
  CHECK (profile_visibility_status IN ('visible', 'hidden'));

ALTER TABLE public.users
  DROP CONSTRAINT IF EXISTS users_account_status_check;

ALTER TABLE public.users
  ADD CONSTRAINT users_account_status_check
  CHECK (account_status IN ('active', 'suspended', 'banned'));

CREATE INDEX IF NOT EXISTS idx_users_account_status
  ON public.users(account_status);

CREATE INDEX IF NOT EXISTS idx_users_profile_visibility_status
  ON public.users(profile_visibility_status);

CREATE INDEX IF NOT EXISTS idx_users_moderation_status
  ON public.users(moderation_status);

CREATE INDEX IF NOT EXISTS idx_users_user_facing_visibility
  ON public.users(account_status, profile_visibility_status, moderation_status, onboarding_complete);

ALTER TABLE public.moderation_events
  DROP CONSTRAINT IF EXISTS moderation_events_event_type_check;

ALTER TABLE public.moderation_events
  ADD CONSTRAINT moderation_events_event_type_check
  CHECK (
    event_type IN (
      'user_report',
      'user_block',
      'content_filter_flag',
      'admin_enforcement'
    )
  );

CREATE OR REPLACE FUNCTION public.require_admin_enforcement_reason(p_reason TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_reason TEXT := NULLIF(BTRIM(COALESCE(p_reason, '')), '');
BEGIN
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'enforcement reason required';
  END IF;

  RETURN v_reason;
END;
$$;

CREATE OR REPLACE FUNCTION public.log_admin_enforcement_event(
  p_admin_user_id UUID,
  p_target_user_id UUID,
  p_action TEXT,
  p_reason TEXT,
  p_report_id UUID DEFAULT NULL,
  p_status TEXT DEFAULT 'resolved',
  p_details JSONB DEFAULT '{}'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_user_id UUID;
  v_event_id UUID;
BEGIN
  IF p_admin_user_id IS DISTINCT FROM public.current_admin_user_id() THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  SELECT au.user_id
  INTO v_actor_user_id
  FROM public.admin_users au
  WHERE au.id = p_admin_user_id
    AND au.status = 'active'
  LIMIT 1;

  IF v_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  INSERT INTO public.moderation_events (
    event_type,
    priority,
    actor_user_id,
    target_user_id,
    report_id,
    source,
    details,
    status,
    admin_email,
    review_due_at
  )
  VALUES (
    'admin_enforcement',
    'high',
    v_actor_user_id,
    p_target_user_id,
    p_report_id,
    'admin',
    jsonb_build_object(
      'action', p_action,
      'reason', p_reason
    ) || COALESCE(p_details, '{}'::JSONB),
    p_status,
    'support@facemeet.app',
    now()
  )
  RETURNING id INTO v_event_id;

  RETURN v_event_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_hide_profile(
  target_user_id UUID,
  reason TEXT
)
RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_reason TEXT;
  v_user public.users;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'moderator']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  v_reason := public.require_admin_enforcement_reason(reason);

  UPDATE public.users
  SET profile_visibility_status = 'hidden',
      profile_hidden_reason = v_reason,
      profile_hidden_at = now(),
      profile_hidden_by = v_admin_user_id
  WHERE id = target_user_id
  RETURNING * INTO v_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'target user not found';
  END IF;

  PERFORM public.log_admin_action(
    'admin_hide_profile',
    'user',
    target_user_id::TEXT,
    jsonb_build_object('reason', v_reason)
  );
  PERFORM public.log_admin_enforcement_event(v_admin_user_id, target_user_id, 'hide_profile', v_reason);

  RETURN v_user;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_unhide_profile(
  target_user_id UUID,
  reason TEXT
)
RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_reason TEXT;
  v_user public.users;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'moderator']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  v_reason := public.require_admin_enforcement_reason(reason);

  UPDATE public.users
  SET profile_visibility_status = 'visible',
      profile_hidden_reason = NULL,
      profile_hidden_at = NULL,
      profile_hidden_by = NULL
  WHERE id = target_user_id
  RETURNING * INTO v_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'target user not found';
  END IF;

  PERFORM public.log_admin_action(
    'admin_unhide_profile',
    'user',
    target_user_id::TEXT,
    jsonb_build_object('reason', v_reason)
  );
  PERFORM public.log_admin_enforcement_event(v_admin_user_id, target_user_id, 'unhide_profile', v_reason);

  RETURN v_user;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_suspend_user(
  target_user_id UUID,
  reason TEXT
)
RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_reason TEXT;
  v_user public.users;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'moderator']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  v_reason := public.require_admin_enforcement_reason(reason);

  UPDATE public.users
  SET account_status = 'suspended',
      account_status_reason = v_reason,
      account_status_updated_at = now(),
      account_status_updated_by = v_admin_user_id,
      profile_visibility_status = 'hidden',
      profile_hidden_reason = v_reason,
      profile_hidden_at = COALESCE(profile_hidden_at, now()),
      profile_hidden_by = COALESCE(profile_hidden_by, v_admin_user_id)
  WHERE id = target_user_id
  RETURNING * INTO v_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'target user not found';
  END IF;

  PERFORM public.log_admin_action(
    'admin_suspend_user',
    'user',
    target_user_id::TEXT,
    jsonb_build_object('reason', v_reason)
  );
  PERFORM public.log_admin_enforcement_event(v_admin_user_id, target_user_id, 'suspend_user', v_reason);

  RETURN v_user;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_unsuspend_user(
  target_user_id UUID,
  reason TEXT
)
RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_reason TEXT;
  v_user public.users;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'moderator']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  v_reason := public.require_admin_enforcement_reason(reason);

  UPDATE public.users
  SET account_status = 'active',
      account_status_reason = v_reason,
      account_status_updated_at = now(),
      account_status_updated_by = v_admin_user_id
  WHERE id = target_user_id
    AND account_status = 'suspended'
  RETURNING * INTO v_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'target suspended user not found';
  END IF;

  PERFORM public.log_admin_action(
    'admin_unsuspend_user',
    'user',
    target_user_id::TEXT,
    jsonb_build_object('reason', v_reason)
  );
  PERFORM public.log_admin_enforcement_event(v_admin_user_id, target_user_id, 'unsuspend_user', v_reason);

  RETURN v_user;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_ban_user(
  target_user_id UUID,
  reason TEXT
)
RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_reason TEXT;
  v_user public.users;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'moderator']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  v_reason := public.require_admin_enforcement_reason(reason);

  UPDATE public.users
  SET account_status = 'banned',
      account_status_reason = v_reason,
      account_status_updated_at = now(),
      account_status_updated_by = v_admin_user_id,
      profile_visibility_status = 'hidden',
      profile_hidden_reason = v_reason,
      profile_hidden_at = COALESCE(profile_hidden_at, now()),
      profile_hidden_by = COALESCE(profile_hidden_by, v_admin_user_id)
  WHERE id = target_user_id
  RETURNING * INTO v_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'target user not found';
  END IF;

  PERFORM public.log_admin_action(
    'admin_ban_user',
    'user',
    target_user_id::TEXT,
    jsonb_build_object('reason', v_reason)
  );
  PERFORM public.log_admin_enforcement_event(v_admin_user_id, target_user_id, 'ban_user', v_reason);

  RETURN v_user;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_restore_user(
  target_user_id UUID,
  reason TEXT
)
RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_reason TEXT;
  v_user public.users;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'moderator']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  v_reason := public.require_admin_enforcement_reason(reason);

  UPDATE public.users
  SET account_status = 'active',
      account_status_reason = v_reason,
      account_status_updated_at = now(),
      account_status_updated_by = v_admin_user_id
  WHERE id = target_user_id
    AND account_status = 'banned'
  RETURNING * INTO v_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'target banned user not found';
  END IF;

  PERFORM public.log_admin_action(
    'admin_restore_user',
    'user',
    target_user_id::TEXT,
    jsonb_build_object('reason', v_reason)
  );
  PERFORM public.log_admin_enforcement_event(v_admin_user_id, target_user_id, 'restore_user', v_reason);

  RETURN v_user;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_remove_profile_video(
  target_user_id UUID,
  reason TEXT
)
RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_reason TEXT;
  v_user public.users;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'moderator']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  v_reason := public.require_admin_enforcement_reason(reason);

  UPDATE public.users
  SET profile_video_url = NULL,
      thumbnail_url = NULL,
      moderation_status = 'rejected',
      moderation_reason = v_reason,
      moderated_at = now(),
      profile_visibility_status = 'hidden',
      profile_hidden_reason = v_reason,
      profile_hidden_at = COALESCE(profile_hidden_at, now()),
      profile_hidden_by = COALESCE(profile_hidden_by, v_admin_user_id),
      profile_video_removed_at = now(),
      profile_video_removed_by = v_admin_user_id,
      profile_video_removed_reason = v_reason
  WHERE id = target_user_id
  RETURNING * INTO v_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'target user not found';
  END IF;

  PERFORM public.log_admin_action(
    'admin_remove_profile_video',
    'user',
    target_user_id::TEXT,
    jsonb_build_object('reason', v_reason)
  );
  PERFORM public.log_admin_enforcement_event(v_admin_user_id, target_user_id, 'remove_profile_video', v_reason);

  RETURN v_user;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_resolve_report(
  report_id UUID,
  status TEXT,
  reason TEXT
)
RETURNS public.user_reports
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_user_id UUID;
  v_reason TEXT;
  v_status TEXT := NULLIF(BTRIM(COALESCE(status, '')), '');
  v_report public.user_reports;
BEGIN
  v_admin_user_id := public.current_admin_user_id();
  IF v_admin_user_id IS NULL OR NOT public.has_admin_role(ARRAY['super_admin', 'moderator']) THEN
    RAISE EXCEPTION 'admin access required';
  END IF;

  IF v_status NOT IN ('reviewing', 'resolved', 'dismissed') THEN
    RAISE EXCEPTION 'invalid report status';
  END IF;

  v_reason := public.require_admin_enforcement_reason(reason);

  UPDATE public.user_reports
  SET status = v_status
  WHERE id = report_id
  RETURNING * INTO v_report;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'report not found';
  END IF;

  UPDATE public.moderation_events
  SET status = v_status,
      details = details || jsonb_build_object(
        'admin_resolution_reason', v_reason,
        'admin_resolution_status', v_status
      )
  WHERE report_id = admin_resolve_report.report_id;

  PERFORM public.log_admin_action(
    'admin_resolve_report',
    'user_report',
    report_id::TEXT,
    jsonb_build_object(
      'status', v_status,
      'reason', v_reason,
      'reported_user_id', v_report.reported_user_id
    )
  );
  PERFORM public.log_admin_enforcement_event(
    v_admin_user_id,
    v_report.reported_user_id,
    'resolve_report',
    v_reason,
    report_id,
    v_status,
    jsonb_build_object('report_status', v_status)
  );

  RETURN v_report;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_eligible_event_matches(
  p_event_id UUID
)
RETURNS TABLE (
  match_id UUID,
  other_user_first_name TEXT,
  other_user_username TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  PERFORM 1
  FROM public.events
  WHERE id = p_event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'event_not_found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.event_rsvps er
    JOIN public.users self_user
      ON self_user.id = er.user_id
    WHERE er.event_id = p_event_id
      AND er.user_id = v_user_id
      AND er.status = 'approved'
      AND COALESCE(self_user.account_status, 'active') = 'active'
      AND COALESCE(self_user.profile_visibility_status, 'visible') = 'visible'
      AND COALESCE(self_user.moderation_status, 'pending') = 'approved'
  ) THEN
    RAISE EXCEPTION 'attendee_not_approved';
  END IF;

  RETURN QUERY
  SELECT
    m.id AS match_id,
    NULLIF(BTRIM(other_user.first_name), '') AS other_user_first_name,
    NULLIF(BTRIM(other_user.username), '') AS other_user_username
  FROM public.matches m
  JOIN public.users other_user
    ON other_user.id = CASE
      WHEN m.user_1_id = v_user_id THEN m.user_2_id
      ELSE m.user_1_id
    END
  WHERE m.status = 'chat_unlocked'
    AND (m.user_1_id = v_user_id OR m.user_2_id = v_user_id)
    AND COALESCE(other_user.account_status, 'active') = 'active'
    AND COALESCE(other_user.profile_visibility_status, 'visible') = 'visible'
    AND COALESCE(other_user.moderation_status, 'pending') = 'approved'
    AND EXISTS (
      SELECT 1
      FROM public.event_rsvps er_other
      WHERE er_other.event_id = p_event_id
        AND er_other.user_id = other_user.id
        AND er_other.status = 'approved'
    )
  ORDER BY
    COALESCE(NULLIF(BTRIM(other_user.first_name), ''), NULLIF(BTRIM(other_user.username), ''), '') ASC,
    m.created_at ASC;
END;
$$;

DROP FUNCTION IF EXISTS public.admin_get_member_profile(UUID);

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
  account_status TEXT,
  account_status_reason TEXT,
  account_status_updated_at TIMESTAMPTZ,
  profile_visibility_status TEXT,
  profile_hidden_reason TEXT,
  profile_hidden_at TIMESTAMPTZ,
  profile_video_removed_at TIMESTAMPTZ,
  profile_video_removed_reason TEXT,
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
      COALESCE(u.account_status, 'active') AS account_status,
      u.account_status_reason,
      u.account_status_updated_at,
      COALESCE(u.profile_visibility_status, 'visible') AS profile_visibility_status,
      u.profile_hidden_reason,
      u.profile_hidden_at,
      u.profile_video_removed_at,
      u.profile_video_removed_reason,
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
    tu.account_status,
    tu.account_status_reason,
    tu.account_status_updated_at,
    tu.profile_visibility_status,
    tu.profile_hidden_reason,
    tu.profile_hidden_at,
    tu.profile_video_removed_at,
    tu.profile_video_removed_reason,
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
        UNION ALL
        SELECT 11, 'Active account status' WHERE tu.account_status <> 'active'
        UNION ALL
        SELECT 12, 'Visible profile' WHERE tu.profile_visibility_status <> 'visible'
        UNION ALL
        SELECT 13, 'Approved video moderation' WHERE COALESCE(tu.moderation_status, 'pending') <> 'approved'
      ) AS missing
    ) AS missing_required_fields
  FROM target_user tu;
END;
$$;

GRANT EXECUTE ON FUNCTION public.require_admin_enforcement_reason(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_hide_profile(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_unhide_profile(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_suspend_user(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_unsuspend_user(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_ban_user(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_restore_user(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_remove_profile_video(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_report(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_eligible_event_matches(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_member_profile(UUID) TO authenticated;
