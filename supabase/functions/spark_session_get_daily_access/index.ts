import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const ROOM_TTL_SECONDS = 10 * 60;
const TOKEN_TTL_SECONDS = 5 * 60;
const MAX_PARTICIPANTS = 2;
const ALLOWED_MATCH_STATUSES = new Set([
  "matched_pending_session",
  "session_expired",
  "chat_unlocked",
]);

type MatchRow = {
  id: string;
  user_1_id: string;
  user_2_id: string;
  status: string;
  current_session_key: string | null;
};

type SparkSessionRow = {
  id: string;
  match_id: string;
  daily_room_url: string | null;
  started_at: string | null;
  created_at: string;
  status: string;
  initiated_by: string | null;
  session_key: string | null;
  ended_at: string | null;
};

type CanonicalSessionClaim = {
  session: SparkSessionRow;
  createdSession: boolean;
  duplicateGuardCount: number;
  lockUsed: boolean;
};

type UserRow = {
  id: string;
  first_name: string | null;
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizeString(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}

function isUuid(value: string) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function safeDisplayName(firstName: string | null | undefined) {
  const name = normalizeString(firstName);
  return name || "FaceMeet Member";
}

function safeErrorMessage(error: unknown) {
  const text = error instanceof Error ? error.message : String(error ?? "");

  if (
    text.includes("missing_authorization") ||
    text.includes("invalid_authorization") ||
    text.includes("authentication required")
  ) {
    return "authentication required";
  }
  if (text.includes("invalid match")) return "invalid match";
  if (text.includes("match not found")) return "match not found";
  if (text.includes("not authorized for this spark session")) {
    return "not authorized for this spark session";
  }
  if (text.includes("spark session expired")) return "spark session expired";
  if (text.includes("spark session unavailable")) {
    return "spark session unavailable";
  }
  return "Daily video service is temporarily unavailable. Please try again later.";
}

function generateSessionKey() {
  return crypto.randomUUID();
}

function roomNameFromSessionKey(sessionKey: string) {
  return `spark-${sessionKey.toLowerCase().replace(/[^a-z0-9-]/g, "-")}`;
}

function roomNameFromUrl(roomUrl: string) {
  try {
    const url = new URL(roomUrl);
    const segment = url.pathname.split("/").filter(Boolean).pop();
    return segment || null;
  } catch {
    return null;
  }
}

function sessionReferenceTime(session: SparkSessionRow) {
  return session.started_at || session.created_at;
}

function getSessionExpiryIso(session: SparkSessionRow) {
  const referenceMs = new Date(sessionReferenceTime(session)).getTime();
  return new Date(referenceMs + ROOM_TTL_SECONDS * 1000).toISOString();
}

function isSessionExpired(session: SparkSessionRow) {
  if (session.status === "ended" || session.ended_at) return true;
  const expiryMs = new Date(getSessionExpiryIso(session)).getTime();
  return Number.isFinite(expiryMs) ? expiryMs <= Date.now() : true;
}

async function fetchMatch(
  adminClient: SupabaseClient,
  matchId: string,
) {
  const { data, error } = await adminClient
    .from("matches")
    .select("id,user_1_id,user_2_id,status,current_session_key")
    .eq("id", matchId)
    .maybeSingle();

  if (error) throw new Error("match_lookup_failed");
  if (!data) throw new Error("match not found");
  return data as MatchRow;
}

async function fetchUser(
  adminClient: SupabaseClient,
  userId: string,
) {
  const { data, error } = await adminClient
    .from("users")
    .select("id,first_name")
    .eq("id", userId)
    .maybeSingle();

  if (error) throw new Error("user_lookup_failed");
  if (!data) throw new Error("spark session unavailable");
  return data as UserRow;
}

async function fetchSessionByKey(
  adminClient: SupabaseClient,
  matchId: string,
  sessionKey: string,
) {
  const { data, error } = await adminClient
    .from("spark_sessions")
    .select(
      "id,match_id,daily_room_url,started_at,created_at,status,initiated_by,session_key,ended_at",
    )
    .eq("match_id", matchId)
    .eq("session_key", sessionKey)
    .maybeSingle();

  if (error) throw new Error("spark_session_lookup_failed");
  return (data ?? null) as SparkSessionRow | null;
}

async function fetchSessionByKeyWithRetry(
  adminClient: SupabaseClient,
  matchId: string,
  sessionKey: string,
) {
  for (let attempt = 0; attempt < 20; attempt++) {
    const session = await fetchSessionByKey(adminClient, matchId, sessionKey);
    if (session) return session;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return null;
}

async function claimOrReuseSessionKey(
  adminClient: SupabaseClient,
  matchId: string,
) {
  const freshKey = generateSessionKey();
  const { data, error } = await adminClient
    .from("matches")
    .update({ current_session_key: freshKey })
    .eq("id", matchId)
    .is("current_session_key", null)
    .select("current_session_key");

  if (error) throw new Error("spark_session_unavailable");

  if ((data ?? []).length > 0) {
    return { sessionKey: freshKey, claimed: true };
  }

  const match = await fetchMatch(adminClient, matchId);
  if (!match.current_session_key) {
    throw new Error("spark session unavailable");
  }

  return { sessionKey: match.current_session_key, claimed: false };
}

async function clearCurrentSessionKeyIfMatches(
  adminClient: SupabaseClient,
  matchId: string,
  sessionKey: string,
) {
  const { error } = await adminClient
    .from("matches")
    .update({ current_session_key: null })
    .eq("id", matchId)
    .eq("current_session_key", sessionKey);

  if (error) {
    throw new Error("spark session unavailable");
  }
}

async function createDailyRoom(params: {
  dailyApiKey: string;
  sessionKey: string;
}) {
  const roomExpiresAt = new Date(Date.now() + ROOM_TTL_SECONDS * 1000);
  const roomName = roomNameFromSessionKey(params.sessionKey);

  const response = await fetch("https://api.daily.co/v1/rooms", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${params.dailyApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      name: roomName,
      privacy: "private",
      properties: {
        exp: Math.floor(roomExpiresAt.getTime() / 1000),
        max_participants: MAX_PARTICIPANTS,
        eject_at_room_exp: true,
        enable_prejoin_ui: false,
      },
    }),
  });

  if (!response.ok) {
    throw new Error("daily_room_create_failed");
  }

  const data = await response.json() as {
    url?: string;
    name?: string;
  };

  if (!data.url || !data.name) {
    throw new Error("daily_room_create_failed");
  }

  return {
    roomUrl: data.url,
    roomName: data.name,
    roomExpiresAt: roomExpiresAt.toISOString(),
  };
}

async function createDailyMeetingToken(params: {
  dailyApiKey: string;
  roomName: string;
  participantName: string;
  roomExpiresAtIso: string;
}) {
  const roomExpiresAtMs = new Date(params.roomExpiresAtIso).getTime();
  const tokenExpiresAtMs = Math.min(
    roomExpiresAtMs,
    Date.now() + TOKEN_TTL_SECONDS * 1000,
  );

  const response = await fetch("https://api.daily.co/v1/meeting-tokens", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${params.dailyApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      properties: {
        room_name: params.roomName,
        is_owner: false,
        exp: Math.floor(tokenExpiresAtMs / 1000),
        user_name: params.participantName,
        enable_prejoin_ui: false,
      },
    }),
  });

  if (!response.ok) {
    throw new Error("daily_token_create_failed");
  }

  const data = await response.json() as { token?: string };
  if (!data.token) {
    throw new Error("daily_token_create_failed");
  }

  return {
    meetingToken: data.token,
    tokenExpiresAt: new Date(tokenExpiresAtMs).toISOString(),
  };
}

function claimToSessionRow(matchId: string, claim: Record<string, unknown>) {
  const sessionId = normalizeString(claim.session_id);
  const sessionKey = normalizeString(claim.session_key);
  const createdAt = normalizeString(claim.created_at);

  if (!isUuid(sessionId) || !sessionKey || !createdAt) {
    throw new Error("spark session unavailable");
  }

  return {
    id: sessionId,
    match_id: matchId,
    daily_room_url: normalizeString(claim.daily_room_url) || null,
    started_at: normalizeString(claim.started_at) || null,
    created_at: createdAt,
    status: normalizeString(claim.status) || "active",
    initiated_by: normalizeString(claim.initiated_by) || null,
    session_key: sessionKey,
    ended_at: normalizeString(claim.ended_at) || null,
  } as SparkSessionRow;
}

async function claimCanonicalSparkSession(params: {
  adminClient: SupabaseClient;
  matchId: string;
  callerUserId: string;
}) {
  const { data, error } = await params.adminClient.rpc(
    "claim_spark_session_for_daily_access",
    {
      p_match_id: params.matchId,
      p_caller_user_id: params.callerUserId,
    },
  );

  if (error) throw new Error(error.message || "spark session unavailable");
  if (!data || typeof data !== "object") {
    throw new Error("spark session unavailable");
  }

  const claim = data as Record<string, unknown>;
  if (claim.success !== true) {
    throw new Error("spark session unavailable");
  }

  return {
    session: claimToSessionRow(params.matchId, claim),
    createdSession: claim.created_session === true,
    duplicateGuardCount: Number(claim.duplicate_guard_count ?? 0) || 0,
    lockUsed: claim.lock_used === true,
  } as CanonicalSessionClaim;
}

async function fetchSessionById(
  adminClient: SupabaseClient,
  sessionId: string,
) {
  const { data, error } = await adminClient
    .from("spark_sessions")
    .select(
      "id,match_id,daily_room_url,started_at,created_at,status,initiated_by,session_key,ended_at",
    )
    .eq("id", sessionId)
    .maybeSingle();

  if (error) throw new Error("spark_session_lookup_failed");
  return (data ?? null) as SparkSessionRow | null;
}

async function waitForDailyRoomUrl(
  adminClient: SupabaseClient,
  sessionId: string,
) {
  for (let attempt = 0; attempt < 24; attempt++) {
    const session = await fetchSessionById(adminClient, sessionId);
    if (session?.daily_room_url) return session;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return null;
}

async function ensureSessionAccess(params: {
  adminClient: SupabaseClient;
  dailyApiKey: string;
  match: MatchRow;
  callerUserId: string;
  requestedSessionKey: string | null;
}) {
  const claim = await claimCanonicalSparkSession({
    adminClient: params.adminClient,
    matchId: params.match.id,
    callerUserId: params.callerUserId,
  });

  if (claim.session.daily_room_url) {
    return {
      ...claim,
      roomUrl: claim.session.daily_room_url,
      roomExpiresAt: getSessionExpiryIso(claim.session),
    };
  }

  if (!claim.createdSession) {
    const sessionWithRoom = await waitForDailyRoomUrl(
      params.adminClient,
      claim.session.id,
    );
    if (!sessionWithRoom?.daily_room_url) {
      throw new Error("spark session unavailable");
    }

    return {
      ...claim,
      session: sessionWithRoom,
      roomUrl: sessionWithRoom.daily_room_url,
      roomExpiresAt: getSessionExpiryIso(sessionWithRoom),
    };
  }

  const room = await createDailyRoom({
    dailyApiKey: params.dailyApiKey,
    sessionKey: claim.session.session_key || "",
  });

  const { data, error } = await params.adminClient
    .from("spark_sessions")
    .update({ daily_room_url: room.roomUrl })
    .eq("id", claim.session.id)
    .select(
      "id,match_id,daily_room_url,started_at,created_at,status,initiated_by,session_key,ended_at",
    )
    .single();

  if (error) throw new Error("spark session unavailable");

  return {
    ...claim,
    session: data as SparkSessionRow,
    roomUrl: room.roomUrl,
    roomExpiresAt: room.roomExpiresAt,
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  try {
    const authorization = req.headers.get("authorization") ?? "";
    if (!authorization.toLowerCase().startsWith("bearer ")) {
      throw new Error("missing_authorization");
    }

    const token = authorization.replace(/^Bearer\s+/i, "").trim();
    if (!token) {
      throw new Error("invalid_authorization");
    }

    const dailyApiKey = Deno.env.get("DAILY_API_KEY")?.trim() || "";
    if (!dailyApiKey) {
      throw new Error("daily_service_unavailable");
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const { data: authData, error: authError } = await callerClient.auth.getUser();
    if (authError || !authData.user) {
      throw new Error("authentication required");
    }

    const body = await req.json().catch(() => ({}));
    const matchId = normalizeString(body?.match_id);
    const requestedSessionKeyRaw = normalizeString(body?.session_key);
    const requestedSessionKey = requestedSessionKeyRaw || null;

    if (!isUuid(matchId)) {
      throw new Error("invalid match");
    }

    const match = await fetchMatch(adminClient, matchId);
    const callerUserId = authData.user.id;
    if (match.user_1_id !== callerUserId && match.user_2_id !== callerUserId) {
      throw new Error("not authorized for this spark session");
    }

    if (!ALLOWED_MATCH_STATUSES.has(match.status)) {
      throw new Error("spark session unavailable");
    }

    const callerUser = await fetchUser(adminClient, callerUserId);
    const access = await ensureSessionAccess({
      adminClient,
      dailyApiKey,
      match,
      callerUserId,
      requestedSessionKey,
    });

    const roomName = roomNameFromUrl(access.roomUrl);
    if (!roomName) {
      throw new Error("daily_service_unavailable");
    }

    const tokenResult = await createDailyMeetingToken({
      dailyApiKey,
      roomName,
      participantName: safeDisplayName(callerUser.first_name),
      roomExpiresAtIso: access.roomExpiresAt,
    });

    return jsonResponse({
      success: true,
      match_id: match.id,
      session_id: access.session.id,
      session_key: access.session.session_key,
      room_url: access.roomUrl,
      meeting_token: tokenResult.meetingToken,
      room_expires_at: access.roomExpiresAt,
      token_expires_at: tokenResult.tokenExpiresAt,
      max_participants: MAX_PARTICIPANTS,
      lock_used: access.lockUsed,
      duplicate_guard_count: access.duplicateGuardCount,
    });
  } catch (error) {
    return jsonResponse({ error: safeErrorMessage(error) }, 400);
  }
});
