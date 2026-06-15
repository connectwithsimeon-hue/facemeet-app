CREATE OR REPLACE FUNCTION public.submit_spark_session_decision(
  p_match_id UUID,
  p_session_id UUID,
  p_session_key TEXT,
  p_decision TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_match public.matches%ROWTYPE;
  v_session public.spark_sessions%ROWTYPE;
  v_decision public.interaction_action_type;
  v_existing_decision public.interaction_action_type;
  v_decision_user_1 public.interaction_action_type;
  v_decision_user_2 public.interaction_action_type;
  v_outcome public.session_outcome_type;
  v_match_status public.match_status_type;
  v_waiting_for_other BOOLEAN := TRUE;
  v_both_decisions_received BOOLEAN := FALSE;
  v_chat_unlocked BOOLEAN := FALSE;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'authentication_required'
    );
  END IF;

  IF p_decision NOT IN ('spark', 'skip', 'pass') THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'invalid_decision'
    );
  END IF;

  v_decision := CASE
    WHEN p_decision = 'pass' THEN 'skip'
    ELSE p_decision
  END::public.interaction_action_type;

  SELECT *
  INTO v_match
  FROM public.matches
  WHERE id = p_match_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'match_not_found'
    );
  END IF;

  IF v_user_id <> v_match.user_1_id AND v_user_id <> v_match.user_2_id THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'not_match_participant'
    );
  END IF;

  SELECT *
  INTO v_session
  FROM public.spark_sessions
  WHERE id = p_session_id
    AND match_id = p_match_id
    AND session_key = p_session_key
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'spark_session_not_found'
    );
  END IF;

  IF v_user_id = v_match.user_1_id THEN
    v_existing_decision := v_session.decision_user_1;
    IF v_existing_decision IS NOT NULL AND v_existing_decision <> v_decision THEN
      RETURN jsonb_build_object(
        'success', FALSE,
        'error', 'decision_already_submitted'
      );
    END IF;

    UPDATE public.spark_sessions
    SET decision_user_1 = COALESCE(decision_user_1, v_decision)
    WHERE id = v_session.id;
  ELSE
    v_existing_decision := v_session.decision_user_2;
    IF v_existing_decision IS NOT NULL AND v_existing_decision <> v_decision THEN
      RETURN jsonb_build_object(
        'success', FALSE,
        'error', 'decision_already_submitted'
      );
    END IF;

    UPDATE public.spark_sessions
    SET decision_user_2 = COALESCE(decision_user_2, v_decision)
    WHERE id = v_session.id;
  END IF;

  SELECT decision_user_1, decision_user_2
  INTO v_decision_user_1, v_decision_user_2
  FROM public.spark_sessions
  WHERE id = v_session.id;

  v_both_decisions_received :=
    v_decision_user_1 IS NOT NULL AND v_decision_user_2 IS NOT NULL;

  IF v_both_decisions_received THEN
    v_waiting_for_other := FALSE;

    IF v_decision_user_1 = 'spark' AND v_decision_user_2 = 'spark' THEN
      v_outcome := 'mutual_spark';
      v_match_status := 'chat_unlocked';
      v_chat_unlocked := TRUE;
    ELSE
      v_outcome := 'no_spark';
      v_match_status := 'session_ended';
    END IF;

    UPDATE public.spark_sessions
    SET outcome = v_outcome,
        status = 'ended',
        ended_at = COALESCE(ended_at, now())
    WHERE id = v_session.id;

    UPDATE public.matches
    SET status = v_match_status,
        current_session_key = NULL
    WHERE id = v_match.id
      AND (current_session_key = p_session_key OR current_session_key IS NULL);
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'waiting_for_other', v_waiting_for_other,
    'both_decisions_received', v_both_decisions_received,
    'outcome', COALESCE(v_outcome::TEXT, ''),
    'chat_unlocked', v_chat_unlocked,
    'decision_user_1', COALESCE(v_decision_user_1::TEXT, ''),
    'decision_user_2', COALESCE(v_decision_user_2::TEXT, ''),
    'match_status', COALESCE(v_match_status::TEXT, v_match.status::TEXT),
    'session_id', v_session.id::TEXT,
    'match_id', v_match.id::TEXT
  );
END;
$$;

REVOKE ALL ON FUNCTION public.submit_spark_session_decision(UUID, UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_spark_session_decision(UUID, UUID, TEXT, TEXT) TO authenticated;
