CREATE OR REPLACE FUNCTION public.claim_spark_session_for_daily_access(
  p_match_id UUID,
  p_caller_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_current_session public.spark_sessions%ROWTYPE;
  v_session public.spark_sessions%ROWTYPE;
  v_new_session_key TEXT;
  v_created_session BOOLEAN := FALSE;
  v_duplicate_guard_count INTEGER := 0;
BEGIN
  IF p_match_id IS NULL OR p_caller_user_id IS NULL THEN
    RAISE EXCEPTION 'invalid match';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_match_id::TEXT, 0));

  SELECT *
  INTO v_match
  FROM public.matches
  WHERE id = p_match_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'match not found';
  END IF;

  IF p_caller_user_id <> v_match.user_1_id
     AND p_caller_user_id <> v_match.user_2_id THEN
    RAISE EXCEPTION 'not authorized for this spark session';
  END IF;

  IF v_match.current_session_key IS NOT NULL THEN
    SELECT *
    INTO v_current_session
    FROM public.spark_sessions
    WHERE match_id = p_match_id
      AND session_key = v_match.current_session_key
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND
       AND v_current_session.ended_at IS NULL
       AND COALESCE(v_current_session.status, 'active') <> 'ended' THEN
      v_session := v_current_session;
    ELSE
      UPDATE public.matches
      SET current_session_key = NULL
      WHERE id = p_match_id
        AND current_session_key = v_match.current_session_key;
    END IF;
  END IF;

  IF v_session.id IS NULL THEN
    SELECT *
    INTO v_session
    FROM public.spark_sessions
    WHERE match_id = p_match_id
      AND ended_at IS NULL
      AND COALESCE(status, 'active') = 'active'
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;
  END IF;

  IF v_session.id IS NULL THEN
    v_new_session_key := gen_random_uuid()::TEXT;

    INSERT INTO public.spark_sessions (
      match_id,
      started_at,
      initiated_by,
      session_key,
      status
    )
    VALUES (
      p_match_id,
      now(),
      p_caller_user_id,
      v_new_session_key,
      'active'
    )
    RETURNING *
    INTO v_session;

    v_created_session := TRUE;
  ELSIF v_session.session_key IS NULL THEN
    v_new_session_key := gen_random_uuid()::TEXT;

    UPDATE public.spark_sessions
    SET session_key = v_new_session_key
    WHERE id = v_session.id
    RETURNING *
    INTO v_session;
  END IF;

  UPDATE public.matches
  SET current_session_key = v_session.session_key
  WHERE id = p_match_id;

  UPDATE public.spark_sessions
  SET status = 'ended',
      ended_at = COALESCE(ended_at, now())
  WHERE match_id = p_match_id
    AND id <> v_session.id
    AND ended_at IS NULL
    AND COALESCE(status, 'active') = 'active';

  GET DIAGNOSTICS v_duplicate_guard_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'success', TRUE,
    'lock_used', TRUE,
    'created_session', v_created_session,
    'duplicate_guard_count', v_duplicate_guard_count,
    'session_id', v_session.id::TEXT,
    'session_key', v_session.session_key,
    'daily_room_url', COALESCE(v_session.daily_room_url, ''),
    'started_at', COALESCE(v_session.started_at::TEXT, ''),
    'created_at', COALESCE(v_session.created_at::TEXT, ''),
    'status', COALESCE(v_session.status, ''),
    'initiated_by', COALESCE(v_session.initiated_by::TEXT, ''),
    'ended_at', COALESCE(v_session.ended_at::TEXT, '')
  );
END;
$$;

REVOKE ALL ON FUNCTION public.claim_spark_session_for_daily_access(UUID, UUID)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_spark_session_for_daily_access(UUID, UUID)
TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_spark_session_for_daily_access(UUID, UUID)
TO service_role;
