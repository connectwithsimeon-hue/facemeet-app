import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const MAX_PARTICIPANTS = 4;
const FALLBACK_ROOM_TTL_SECONDS = 20 * 60;

type LiveTopicRow = {
  id: string;
  creator_user_id: string;
  cohost_user_id: string;
  status: string;
  daily_room_url: string | null;
  daily_room_name: string | null;
  started_at: string | null;
  ends_at: string | null;
  max_speakers: number | null;
};

type UserRow = {
  id: string;
  first_name: string | null;
};

class SafeFunctionError extends Error {
  code: string;
  details?: Record<string, unknown>;

  constructor(code: string, details?: Record<string, unknown>) {
    super(code);
    this.name = "SafeFunctionError";
    this.code = code;
    this.details = details;
  }
}

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
  const name = normalizeString(firstName)
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return (name || "FaceMeet Member").slice(0, 40);
}

function roomNameFromTopicId(liveTopicId: string) {
  return `live-topic-${liveTopicId.toLowerCase().replace(/[^a-z0-9-]/g, "-")}`;
}

function roomNameFromUrl(roomUrl: string) {
  try {
    const url = new URL(roomUrl);
    const segment = url.pathname.split("/").filter(Boolean).pop();
    const roomName = normalizeString(segment);
    if (!roomName) return null;
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(roomName)) return null;
    return roomName;
  } catch {
    return null;
  }
}

function roomExpiresAtIso(topic: LiveTopicRow) {
  const endsAtMs = topic.ends_at ? new Date(topic.ends_at).getTime() : NaN;
  if (Number.isFinite(endsAtMs) && endsAtMs > Date.now()) {
    return new Date(endsAtMs + 5 * 60 * 1000).toISOString();
  }
  return new Date(Date.now() + FALLBACK_ROOM_TTL_SECONDS * 1000).toISOString();
}

function safeDailyProviderMessage(bodyText: string) {
  if (!bodyText.trim()) return "empty";
  try {
    const data = JSON.parse(bodyText) as Record<string, unknown>;
    const candidate =
      data.error ??
      data.info ??
      data.message ??
      data.msg ??
      data.type ??
      "provider_rejected";
    return normalizeString(String(candidate)).slice(0, 120) ||
      "provider_rejected";
  } catch {
    return bodyText.replace(/\s+/g, " ").trim().slice(0, 120) || "unparseable";
  }
}

function safeDailyProviderType(bodyText: string) {
  try {
    const data = JSON.parse(bodyText) as Record<string, unknown>;
    return normalizeString(String(data.type ?? data.error_type ?? data.code ?? ""))
      .slice(0, 80) || "unknown";
  } catch {
    return "unknown";
  }
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
  if (text.includes("invalid_live_topic")) return "invalid live topic";
  if (text.includes("live_topic_not_found")) return "Live Topic not found.";
  if (text.includes("daily_access_denied")) {
    return "You can only join this Live Topic video stage as a host, co-host, or approved speaker.";
  }
  if (text.includes("room_not_live")) {
    return "This Live Topic has not started yet.";
  }
  if (text.includes("room_ended")) return "This Live Topic has ended.";
  return "Could not connect to the Live Topic video. Please try again.";
}

function safeErrorCode(error: unknown) {
  if (error instanceof SafeFunctionError) return error.code;
  const text = error instanceof Error ? error.message : String(error ?? "");
  const knownCodes = [
    "authentication_required",
    "invalid_live_topic",
    "live_topic_not_found",
    "daily_access_denied",
    "room_not_live",
    "room_ended",
    "daily_token_create_failed",
    "daily_token_exp_invalid",
    "daily_token_room_name_missing",
    "daily_token_provider_rejected",
    "daily_room_create_failed",
    "daily_room_reuse_failed",
    "daily_service_unavailable",
  ];
  for (const code of knownCodes) {
    if (text.includes(code) || text.includes(code.replaceAll("_", " "))) {
      return code;
    }
  }
  return "daily_access_failed";
}

function safeErrorDetails(error: unknown) {
  if (error instanceof SafeFunctionError) return error.details;
  return undefined;
}

async function fetchLiveTopic(
  adminClient: SupabaseClient,
  liveTopicId: string,
) {
  const { data, error } = await adminClient
    .from("live_topics")
    .select(
      "id,creator_user_id,cohost_user_id,status,daily_room_url,daily_room_name,started_at,ends_at,max_speakers",
    )
    .eq("id", liveTopicId)
    .maybeSingle();

  if (error) throw new Error("live_topic_lookup_failed");
  if (!data) throw new Error("live_topic_not_found");
  return data as LiveTopicRow;
}

async function fetchPaidStageSpeaker(
  adminClient: SupabaseClient,
  liveTopicId: string,
  userId: string,
) {
  const { data, error } = await adminClient
    .from("live_topic_participants")
    .select("id,role,status")
    .eq("live_topic_id", liveTopicId)
    .eq("user_id", userId)
    .eq("role", "speaker")
    .eq("status", "joined")
    .maybeSingle();

  if (error) throw new Error("stage_access_lookup_failed");
  if (!data) return false;

  const { data: charge, error: chargeError } = await adminClient
    .from("live_topic_stage_charges")
    .select("id")
    .eq("live_topic_id", liveTopicId)
    .eq("user_id", userId)
    .maybeSingle();

  if (chargeError) throw new Error("stage_charge_lookup_failed");
  return Boolean(charge?.id);
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
  if (!data) throw new Error("daily_access_denied");
  return data as UserRow;
}

async function createDailyRoom(params: {
  dailyApiKey: string;
  roomName: string;
  roomExpiresAt: string;
}) {
  const roomExpiresAtMs = new Date(params.roomExpiresAt).getTime();
  const response = await fetch("https://api.daily.co/v1/rooms", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${params.dailyApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      name: params.roomName,
      privacy: "private",
      properties: {
        exp: Math.floor(roomExpiresAtMs / 1000),
        max_participants: MAX_PARTICIPANTS,
        eject_at_room_exp: true,
        enable_prejoin_ui: false,
      },
    }),
  });

  if (!response.ok) {
    throw new Error("daily_room_create_failed");
  }

  const data = await response.json() as { url?: string; name?: string };
  if (!data.url || !data.name) {
    throw new Error("daily_room_create_failed");
  }

  return { roomUrl: data.url, roomName: data.name };
}

async function createDailyMeetingToken(params: {
  dailyApiKey: string;
  roomName: string;
  participantName: string;
  topic: LiveTopicRow;
}) {
  const roomName = normalizeString(params.roomName);
  if (!roomName) {
    throw new SafeFunctionError("daily_token_room_name_missing", {
      room_name_present: false,
    });
  }

  const endsAtMs = params.topic.ends_at
    ? new Date(params.topic.ends_at).getTime()
    : NaN;
  const fallbackExpMs = Date.now() + FALLBACK_ROOM_TTL_SECONDS * 1000;
  const tokenExpiresAtMs = Number.isFinite(endsAtMs) && endsAtMs > Date.now()
    ? Math.min(endsAtMs + 5 * 60 * 1000, fallbackExpMs)
    : fallbackExpMs;
  const exp = Math.floor(tokenExpiresAtMs / 1000);
  if (!Number.isFinite(exp) || exp <= Math.floor(Date.now() / 1000) + 60) {
    throw new SafeFunctionError("daily_token_exp_invalid", {
      exp_in_future: false,
      room_name_present: true,
      participant_name_length: params.participantName.length,
    });
  }

  const response = await fetch("https://api.daily.co/v1/meeting-tokens", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${params.dailyApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      properties: {
        room_name: roomName,
        is_owner: false,
        exp,
        user_name: params.participantName,
        enable_prejoin_ui: false,
      },
    }),
  });

  if (!response.ok) {
    const bodyText = await response.text().catch(() => "");
    throw new SafeFunctionError("daily_token_provider_rejected", {
      daily_status: response.status,
      daily_error_message: safeDailyProviderMessage(bodyText),
      daily_error_type: safeDailyProviderType(bodyText),
      room_name_present: true,
      exp_in_future: true,
      participant_name_length: params.participantName.length,
    });
  }

  const data = await response.json() as { token?: string };
  if (!data.token) {
    throw new SafeFunctionError("daily_token_create_failed", {
      daily_status: response.status,
      daily_error_message: "missing token",
      daily_error_type: "missing_token",
      room_name_present: true,
      exp_in_future: true,
      participant_name_length: params.participantName.length,
    });
  }

  return {
    meetingToken: data.token,
    tokenExpiresAt: new Date(tokenExpiresAtMs).toISOString(),
  };
}

async function ensureDailyRoom(params: {
  adminClient: SupabaseClient;
  dailyApiKey: string;
  topic: LiveTopicRow;
}) {
  const existingRoomName = normalizeString(params.topic.daily_room_name) ||
    (params.topic.daily_room_url
      ? roomNameFromUrl(params.topic.daily_room_url) ?? ""
      : "");

  if (params.topic.daily_room_url && existingRoomName) {
    return {
      topic: params.topic,
      roomUrl: params.topic.daily_room_url,
      roomName: existingRoomName,
      roomExpiresAt: roomExpiresAtIso(params.topic),
    };
  }

  const roomExpiresAt = roomExpiresAtIso(params.topic);
  const room = await createDailyRoom({
    dailyApiKey: params.dailyApiKey,
    roomName: roomNameFromTopicId(params.topic.id),
    roomExpiresAt,
  });

  const { data, error } = await params.adminClient
    .from("live_topics")
    .update({ daily_room_url: room.roomUrl, daily_room_name: room.roomName })
    .eq("id", params.topic.id)
    .eq("status", "live")
    .select(
      "id,creator_user_id,cohost_user_id,status,daily_room_url,daily_room_name,started_at,ends_at,max_speakers",
    )
    .single();

  if (error) throw new Error("daily_room_reuse_failed");

  return {
    topic: data as LiveTopicRow,
    roomUrl: room.roomUrl,
    roomName: room.roomName,
    roomExpiresAt,
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
    if (!token) throw new Error("invalid_authorization");

    const dailyApiKey = Deno.env.get("DAILY_API_KEY")?.trim() || "";
    if (!dailyApiKey) throw new Error("daily_service_unavailable");

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const { data: authData, error: authError } = await callerClient.auth.getUser();
    if (authError || !authData.user) throw new Error("authentication required");

    const body = await req.json().catch(() => ({}));
    const liveTopicId = normalizeString(body?.live_topic_id);
    if (!isUuid(liveTopicId)) throw new Error("invalid_live_topic");

    const topic = await fetchLiveTopic(adminClient, liveTopicId);
    const callerUserId = authData.user.id;
    const isHostOrCohost =
      topic.creator_user_id === callerUserId || topic.cohost_user_id === callerUserId;
    const isPaidStageSpeaker = isHostOrCohost
      ? false
      : await fetchPaidStageSpeaker(adminClient, liveTopicId, callerUserId);
    if (!isHostOrCohost && !isPaidStageSpeaker) throw new Error("daily_access_denied");

    if (topic.status === "ended" || topic.status === "cancelled" || topic.status === "declined") {
      throw new Error("room_ended");
    }
    if (topic.status !== "live") throw new Error("room_not_live");

    const callerUser = await fetchUser(adminClient, callerUserId);
    const access = await ensureDailyRoom({ adminClient, dailyApiKey, topic });
    const tokenResult = await createDailyMeetingToken({
      dailyApiKey,
      roomName: access.roomName,
      participantName: safeDisplayName(callerUser.first_name),
      topic: access.topic,
    });

    return jsonResponse({
      success: true,
      live_topic_id: access.topic.id,
      room_url: access.roomUrl,
      meeting_token: tokenResult.meetingToken,
      room_expires_at: access.roomExpiresAt,
      token_expires_at: tokenResult.tokenExpiresAt,
      max_participants: Math.min(topic.max_speakers ?? MAX_PARTICIPANTS, MAX_PARTICIPANTS),
    });
  } catch (error) {
    const details = safeErrorDetails(error);
    return jsonResponse({
      error: safeErrorMessage(error),
      error_code: safeErrorCode(error),
      ...(details ? { error_details: details } : {}),
    }, 400);
  }
});
