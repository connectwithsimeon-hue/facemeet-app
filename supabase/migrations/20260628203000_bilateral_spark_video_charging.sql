-- Bilateral Spark charging for private Spark Sessions and Live Topic co-hosts.
-- This migration is intentionally additive and idempotent.

ALTER TABLE public.spark_sessions
  ADD COLUMN IF NOT EXISTS spark_charge_initiator_user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS spark_charge_participant_user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS initiator_spark_charged_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS participant_spark_charged_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS initiator_spark_refunded_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS participant_spark_refunded_at TIMESTAMPTZ;

ALTER TABLE public.live_topic_participants
  ADD COLUMN IF NOT EXISTS spark_charged_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS spark_charge_amount INTEGER NOT NULL DEFAULT 0 CHECK (spark_charge_amount >= 0);

CREATE INDEX IF NOT EXISTS idx_spark_sessions_charge_markers
  ON public.spark_sessions(match_id, session_key, initiator_spark_charged_at, participant_spark_charged_at);

CREATE INDEX IF NOT EXISTS idx_live_topic_participants_spark_charge
  ON public.live_topic_participants(live_topic_id, user_id, role, spark_charged_at);

CREATE OR REPLACE FUNCTION public.charge_spark_session_participants(
  p_match_id UUID,
  p_session_key TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_match public.matches%ROWTYPE;
  v_session public.spark_sessions%ROWTYPE;
  v_initiator_id UUID;
  v_participant_id UUID;
  v_initiator_balance INTEGER;
  v_participant_balance INTEGER;
  v_charge_initiator BOOLEAN := FALSE;
  v_charge_participant BOOLEAN := FALSE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF p_match_id IS NULL THEN
    RAISE EXCEPTION 'invalid_match';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_match_id::TEXT, 0));

  SELECT *
  INTO v_match
  FROM public.matches
  WHERE id = p_match_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'match_not_found';
  END IF;

  IF v_uid <> v_match.user_1_id AND v_uid <> v_match.user_2_id THEN
    RAISE EXCEPTION 'not_authorized_for_this_spark_session';
  END IF;

  IF p_session_key IS NOT NULL AND trim(p_session_key) <> '' THEN
    SELECT *
    INTO v_session
    FROM public.spark_sessions
    WHERE match_id = p_match_id
      AND session_key = p_session_key
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;
  ELSE
    SELECT *
    INTO v_session
    FROM public.spark_sessions
    WHERE match_id = p_match_id
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'spark_session_not_found';
  END IF;

  IF COALESCE(v_session.user_1_ready, false) IS DISTINCT FROM TRUE
     OR COALESCE(v_session.user_2_ready, false) IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'spark_session_not_fully_joined';
  END IF;

  v_initiator_id := v_session.initiated_by;
  IF v_initiator_id IS NULL
     OR (v_initiator_id <> v_match.user_1_id AND v_initiator_id <> v_match.user_2_id) THEN
    v_initiator_id := v_match.user_1_id;
  END IF;

  v_participant_id := CASE
    WHEN v_initiator_id = v_match.user_1_id THEN v_match.user_2_id
    ELSE v_match.user_1_id
  END;

  v_charge_initiator := v_session.initiator_spark_charged_at IS NULL;
  v_charge_participant := v_session.participant_spark_charged_at IS NULL;

  IF v_charge_initiator THEN
    SELECT spark_balance
    INTO v_initiator_balance
    FROM public.users
    WHERE id = v_initiator_id
    FOR UPDATE;

    IF COALESCE(v_initiator_balance, 0) < 1 THEN
      RAISE EXCEPTION 'not_enough_sparks_initiator';
    END IF;
  END IF;

  IF v_charge_participant THEN
    SELECT spark_balance
    INTO v_participant_balance
    FROM public.users
    WHERE id = v_participant_id
    FOR UPDATE;

    IF COALESCE(v_participant_balance, 0) < 1 THEN
      RAISE EXCEPTION 'not_enough_sparks_participant';
    END IF;
  END IF;

  IF v_charge_initiator THEN
    UPDATE public.users
    SET spark_balance = spark_balance - 1
    WHERE id = v_initiator_id;
  END IF;

  IF v_charge_participant THEN
    UPDATE public.users
    SET spark_balance = spark_balance - 1
    WHERE id = v_participant_id;
  END IF;

  UPDATE public.spark_sessions
  SET spark_charge_initiator_user_id = COALESCE(spark_charge_initiator_user_id, v_initiator_id),
      spark_charge_participant_user_id = COALESCE(spark_charge_participant_user_id, v_participant_id),
      initiator_spark_charged_at = COALESCE(initiator_spark_charged_at, CASE WHEN v_charge_initiator THEN now() ELSE NULL END),
      participant_spark_charged_at = COALESCE(participant_spark_charged_at, CASE WHEN v_charge_participant THEN now() ELSE NULL END)
  WHERE id = v_session.id
  RETURNING * INTO v_session;

  RETURN jsonb_build_object(
    'success', TRUE,
    'session_id', v_session.id,
    'initiator_user_id', v_initiator_id,
    'participant_user_id', v_participant_id,
    'initiator_charged_now', v_charge_initiator,
    'participant_charged_now', v_charge_participant,
    'initiator_already_charged', NOT v_charge_initiator,
    'participant_already_charged', NOT v_charge_participant
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.refund_spark_session_participants(
  p_match_id UUID,
  p_session_key TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_match public.matches%ROWTYPE;
  v_session public.spark_sessions%ROWTYPE;
  v_refund_initiator BOOLEAN := FALSE;
  v_refund_participant BOOLEAN := FALSE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  IF p_match_id IS NULL THEN
    RAISE EXCEPTION 'invalid_match';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_match_id::TEXT, 0));

  SELECT *
  INTO v_match
  FROM public.matches
  WHERE id = p_match_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'match_not_found';
  END IF;

  IF v_uid <> v_match.user_1_id AND v_uid <> v_match.user_2_id THEN
    RAISE EXCEPTION 'not_authorized_for_this_spark_session';
  END IF;

  IF p_session_key IS NOT NULL AND trim(p_session_key) <> '' THEN
    SELECT *
    INTO v_session
    FROM public.spark_sessions
    WHERE match_id = p_match_id
      AND session_key = p_session_key
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;
  ELSE
    SELECT *
    INTO v_session
    FROM public.spark_sessions
    WHERE match_id = p_match_id
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'spark_session_not_found';
  END IF;

  v_refund_initiator :=
    v_session.spark_charge_initiator_user_id IS NOT NULL
    AND v_session.initiator_spark_charged_at IS NOT NULL
    AND v_session.initiator_spark_refunded_at IS NULL;

  v_refund_participant :=
    v_session.spark_charge_participant_user_id IS NOT NULL
    AND v_session.participant_spark_charged_at IS NOT NULL
    AND v_session.participant_spark_refunded_at IS NULL;

  IF v_refund_initiator THEN
    UPDATE public.users
    SET spark_balance = spark_balance + 1
    WHERE id = v_session.spark_charge_initiator_user_id;
  END IF;

  IF v_refund_participant THEN
    UPDATE public.users
    SET spark_balance = spark_balance + 1
    WHERE id = v_session.spark_charge_participant_user_id;
  END IF;

  UPDATE public.spark_sessions
  SET initiator_spark_refunded_at = COALESCE(initiator_spark_refunded_at, CASE WHEN v_refund_initiator THEN now() ELSE NULL END),
      participant_spark_refunded_at = COALESCE(participant_spark_refunded_at, CASE WHEN v_refund_participant THEN now() ELSE NULL END)
  WHERE id = v_session.id
  RETURNING * INTO v_session;

  RETURN jsonb_build_object(
    'success', TRUE,
    'session_id', v_session.id,
    'initiator_refunded_now', v_refund_initiator,
    'participant_refunded_now', v_refund_participant
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.respond_live_topic_cohost_invite(
  p_live_topic_id UUID,
  p_accept BOOLEAN
) RETURNS public.live_topics
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_topic public.live_topics%ROWTYPE;
  v_balance INTEGER;
  v_already_charged BOOLEAN := FALSE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT *
  INTO v_topic
  FROM public.live_topics
  WHERE id = p_live_topic_id
    AND cohost_user_id = v_uid
    AND status = 'pending_cohost_acceptance'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invite_not_available';
  END IF;

  IF p_accept THEN
    SELECT COALESCE(spark_charged_at IS NOT NULL, false)
    INTO v_already_charged
    FROM public.live_topic_participants
    WHERE live_topic_id = p_live_topic_id
      AND user_id = v_uid
      AND role = 'cohost'
    FOR UPDATE;

    IF NOT COALESCE(v_already_charged, false) THEN
      SELECT spark_balance
      INTO v_balance
      FROM public.users
      WHERE id = v_uid
      FOR UPDATE;

      IF COALESCE(v_balance, 0) < 1 THEN
        RAISE EXCEPTION 'not_enough_sparks_cohost';
      END IF;

      UPDATE public.users
      SET spark_balance = spark_balance - 1
      WHERE id = v_uid;
    END IF;

    UPDATE public.live_topic_participants
    SET status = 'accepted',
        updated_at = now(),
        spark_charged_at = COALESCE(spark_charged_at, now()),
        spark_charge_amount = CASE
          WHEN COALESCE(spark_charge_amount, 0) = 0 THEN 1
          ELSE spark_charge_amount
        END
    WHERE live_topic_id = p_live_topic_id
      AND user_id = v_uid
      AND role = 'cohost';

    UPDATE public.live_topics
    SET status = 'ready'
    WHERE id = p_live_topic_id
    RETURNING * INTO v_topic;

    INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type, metadata)
    VALUES (
      p_live_topic_id,
      v_uid,
      'cohost_accepted',
      jsonb_build_object(
        'spark_cost', CASE WHEN COALESCE(v_already_charged, false) THEN 0 ELSE 1 END,
        'already_charged', COALESCE(v_already_charged, false)
      )
    );
  ELSE
    UPDATE public.live_topic_participants
    SET status = 'declined', updated_at = now()
    WHERE live_topic_id = p_live_topic_id
      AND user_id = v_uid
      AND role = 'cohost';

    UPDATE public.live_topics
    SET status = 'declined', ended_at = now()
    WHERE id = p_live_topic_id
    RETURNING * INTO v_topic;

    INSERT INTO public.live_topic_events(live_topic_id, actor_user_id, event_type)
    VALUES (p_live_topic_id, v_uid, 'cohost_declined');
  END IF;

  RETURN v_topic;
END;
$$;

REVOKE ALL ON FUNCTION public.charge_spark_session_participants(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.refund_spark_session_participants(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.respond_live_topic_cohost_invite(UUID, BOOLEAN) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.charge_spark_session_participants(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.refund_spark_session_participants(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.respond_live_topic_cohost_invite(UUID, BOOLEAN) TO authenticated;
