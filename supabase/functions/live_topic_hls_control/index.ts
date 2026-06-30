import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const FALLBACK_ROOM_TTL_SECONDS = 20 * 60;
const MAX_PARTICIPANTS = 4;
const DAILY_START_TIMEOUT_MS = 10_000;
const DAILY_STOP_TIMEOUT_MS = 8_000;

type LiveTopicRow = {
  id: string;
  creator_user_id: string;
  cohost_user_id: string;
  status: string;
  daily_room_url: string | null;
  daily_room_name: string | null;
  ends_at: string | null;
  hls_playback_url: string | null;
  hls_status: string | null;
  hls_started_at: string | null;
  hls_ended_at: string | null;
};

type HlsErrorDiagnostics = {
  error_code: string;
  error_message?: string;
  daily_status?: number;
  daily_response_keys?: string[];
  rtmp_url_usable?: boolean;
  playback_url_usable?: boolean;
};

type SafeHlsError = Error & {
  hlsDiagnostics?: HlsErrorDiagnostics;
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
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{12}$/i
    .test(value);
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

function roomNameFromTopicId(liveTopicId: string) {
  return `live-topic-${liveTopicId.toLowerCase().replace(/[^a-z0-9-]/g, "-")}`;
}

function roomExpiresAtIso(topic: LiveTopicRow) {
  const endsAtMs = topic.ends_at ? new Date(topic.ends_at).getTime() : NaN;
  if (Number.isFinite(endsAtMs) && endsAtMs > Date.now()) {
    return new Date(endsAtMs + 5 * 60 * 1000).toISOString();
  }
  return new Date(Date.now() + FALLBACK_ROOM_TTL_SECONDS * 1000).toISOString();
}

function safeDailyMessage(bodyText: string) {
  if (!bodyText.trim()) return "empty";
  try {
    const data = JSON.parse(bodyText) as Record<string, unknown>;
    const candidate =
      data.error ?? data.info ?? data.message ?? data.msg ?? data.type ??
        "provider_rejected";
    return normalizeString(String(candidate)).slice(0, 120) ||
      "provider_rejected";
  } catch {
    return bodyText.replace(/\s+/g, " ").trim().slice(0, 120) || "unparseable";
  }
}

function safeErrorCode(error: unknown) {
  const details = (error as SafeHlsError | undefined)?.hlsDiagnostics;
  if (details?.error_code) return details.error_code;

  const raw = error instanceof Error ? error.message : String(error ?? "");
  const knownCodes = [
    "authentication_required",
    "missing_live_topic_id",
    "invalid_live_topic",
    "invalid_action",
    "live_topic_not_found",
    "not_host_or_cohost",
    "unauthorized_user",
    "topic_not_live",
    "topic_ended",
    "daily_room_missing",
    "missing_daily_room_name",
    "daily_hls_output_not_configured",
    "invalid_rtmp_config",
    "invalid_playback_config",
    "daily_hls_output_invalid",
    "daily_start_timeout",
    "daily_start_fetch_failed",
    "daily_start_failed",
    "daily_response_unexpected",
    "daily_stop_timeout",
    "daily_stop_fetch_failed",
    "db_update_failed",
    "daily_hls_start_failed",
    "daily_hls_stop_failed",
    "daily_service_unavailable",
  ];
  for (const code of knownCodes) {
    if (raw.includes(code)) return code;
  }
  return "live_topic_hls_failed";
}

function safeErrorMessage(error: unknown) {
  const code = safeErrorCode(error);
  switch (code) {
    case "authentication_required":
      return "Authentication required.";
    case "missing_live_topic_id":
      return "Missing Live Topic.";
    case "invalid_live_topic":
      return "Invalid Live Topic.";
    case "invalid_action":
      return "Invalid HLS action.";
    case "live_topic_not_found":
      return "Live Topic not found.";
    case "not_host_or_cohost":
    case "unauthorized_user":
      return "Only a host or co-host can control Live Topic playback.";
    case "topic_not_live":
      return "This Live Topic is not live yet.";
    case "topic_ended":
      return "This Live Topic has ended.";
    case "daily_room_missing":
    case "missing_daily_room_name":
      return "Live Topic video room is not ready yet.";
    case "daily_hls_output_not_configured":
      return "Live playback is not configured yet.";
    case "daily_hls_output_invalid":
    case "invalid_rtmp_config":
    case "invalid_playback_config":
      return "Live playback is not configured correctly yet.";
    case "daily_start_timeout":
    case "daily_start_fetch_failed":
    case "daily_start_failed":
    case "daily_response_unexpected":
      return "Live playback could not start yet.";
    case "daily_stop_timeout":
    case "daily_stop_fetch_failed":
      return "Live playback could not stop cleanly yet.";
    case "db_update_failed":
      return "Live playback state could not be saved.";
    case "daily_service_unavailable":
      return "Live playback service is unavailable.";
    default:
      return "Live playback could not be updated.";
  }
}

function logSafe(event: string, data: Record<string, unknown>) {
  console.log(JSON.stringify({ event, ...data }));
}

function makeHlsError(
  code: string,
  diagnostics: Partial<HlsErrorDiagnostics> = {},
) {
  const error = new Error(code) as SafeHlsError;
  error.hlsDiagnostics = {
    error_code: code,
    ...diagnostics,
  };
  return error;
}

function safeDiagnosticArray(value: unknown) {
  if (!Array.isArray(value)) return undefined;
  return value
    .map((item) => normalizeString(item))
    .filter(Boolean)
    .slice(0, 20);
}

function safeErrorDiagnostics(error: unknown): HlsErrorDiagnostics {
  const safeError = error as SafeHlsError | undefined;
  const details = safeError?.hlsDiagnostics ?? {};
  const code = details.error_code || safeErrorCode(error);
  const rawMessage = details.error_message ||
    (error instanceof Error ? error.message : String(error ?? ""));

  return {
    error_code: code,
    error_message: normalizeString(rawMessage).slice(0, 160) || code,
    daily_status: typeof details.daily_status === "number"
      ? details.daily_status
      : undefined,
    daily_response_keys: safeDiagnosticArray(details.daily_response_keys),
    rtmp_url_usable: typeof details.rtmp_url_usable === "boolean"
      ? details.rtmp_url_usable
      : undefined,
    playback_url_usable: typeof details.playback_url_usable === "boolean"
      ? details.playback_url_usable
      : undefined,
  };
}

function extractPlaybackUrl(value: unknown): string {
  if (typeof value === "string") {
    const trimmed = value.trim();
    return /^https:\/\//i.test(trimmed) && /\.m3u8(\?|$)/i.test(trimmed)
      ? trimmed
      : "";
  }
  if (!value || typeof value !== "object") return "";

  const data = value as Record<string, unknown>;
  const directCandidates = [
    data.hls_playback_url,
    data.hlsPlaybackUrl,
    data.playback_url,
    data.playbackUrl,
    data.hls_url,
    data.hlsUrl,
    data.url,
  ];

  for (const candidate of directCandidates) {
    const url = extractPlaybackUrl(candidate);
    if (url) return url;
  }

  for (const nestedKey of ["hls", "live_streaming", "liveStreaming", "stream", "streaming"]) {
    const url = extractPlaybackUrl(data[nestedKey]);
    if (url) return url;
  }

  for (const arrayKey of ["endpoints", "outputs", "streams"]) {
    const items = data[arrayKey];
    if (Array.isArray(items)) {
      for (const item of items) {
        const url = extractPlaybackUrl(item);
        if (url) return url;
      }
    }
  }

  return "";
}

function rtmpUrlLooksUsable(value: string) {
  try {
    const url = new URL(value);
    const pathSegments = url.pathname.split("/").filter(Boolean);
    return url.protocol === "rtmps:" &&
      pathSegments.length >= 2 &&
      pathSegments[0].toLowerCase() === "live";
  } catch {
    return false;
  }
}

function playbackUrlLooksUsable(value: string) {
  return Boolean(extractPlaybackUrl(value));
}

async function fetchLiveTopic(
  adminClient: SupabaseClient,
  liveTopicId: string,
) {
  const { data, error } = await adminClient
    .from("live_topics")
    .select(
      "id,creator_user_id,cohost_user_id,status,daily_room_url,daily_room_name,ends_at,hls_playback_url,hls_status,hls_started_at,hls_ended_at",
    )
    .eq("id", liveTopicId)
    .maybeSingle();

  if (error) throw new Error("live_topic_lookup_failed");
  if (!data) throw new Error("live_topic_not_found");
  return data as LiveTopicRow;
}

async function userHasLiveTopicViewerAccess(
  adminClient: SupabaseClient,
  liveTopicId: string,
  userId: string,
) {
  const { data, error } = await adminClient
    .from("live_topic_viewers")
    .select("id")
    .eq("live_topic_id", liveTopicId)
    .eq("user_id", userId)
    .not("access_type", "is", null)
    .maybeSingle();

  if (error) {
    logSafe("live_topic_hls_viewer_access_lookup_failed", {
      live_topic_id: liveTopicId,
      error_code: "viewer_access_lookup_failed",
    });
    return false;
  }

  return Boolean(data?.id);
}

function resolveRoomName(topic: LiveTopicRow) {
  const roomName = normalizeString(topic.daily_room_name) ||
    (topic.daily_room_url ? roomNameFromUrl(topic.daily_room_url) ?? "" : "");
  if (!roomName) throw new Error("daily_room_missing");
  return roomName;
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

  if (!response.ok) throw new Error("daily_room_create_failed");
  const data = await response.json() as { url?: string; name?: string };
  if (!data.url || !data.name) throw new Error("daily_room_create_failed");
  return { roomUrl: data.url, roomName: data.name };
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
    return { topic: params.topic, roomName: existingRoomName };
  }

  const room = await createDailyRoom({
    dailyApiKey: params.dailyApiKey,
    roomName: roomNameFromTopicId(params.topic.id),
    roomExpiresAt: roomExpiresAtIso(params.topic),
  });

  const { data, error } = await params.adminClient
    .from("live_topics")
    .update({ daily_room_url: room.roomUrl, daily_room_name: room.roomName })
    .eq("id", params.topic.id)
    .eq("status", "live")
    .select(
      "id,creator_user_id,cohost_user_id,status,daily_room_url,daily_room_name,ends_at,hls_playback_url,hls_status,hls_started_at,hls_ended_at",
    )
    .single();

  if (error) throw new Error("daily_room_create_failed");
  return { topic: data as LiveTopicRow, roomName: room.roomName };
}

async function callDailyLiveStreaming(params: {
  dailyApiKey: string;
  roomName: string;
  action: "start" | "stop";
  rtmpUrl?: string;
  liveTopicId?: string;
  adminClient?: SupabaseClient;
  rtmpUrlUsable?: boolean;
  playbackUrlUsable?: boolean;
}) {
  const requestBody = params.action === "start"
    ? JSON.stringify({
      rtmpUrl: params.rtmpUrl,
    })
    : undefined;

  const controller = new AbortController();
  const timeoutMs = params.action === "start"
    ? DAILY_START_TIMEOUT_MS
    : DAILY_STOP_TIMEOUT_MS;
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
  let response: Response;
  try {
    response = await fetch(
      `https://api.daily.co/v1/rooms/${
        encodeURIComponent(params.roomName)
      }/live-streaming/${params.action}`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${params.dailyApiKey}`,
          "Content-Type": "application/json",
        },
        ...(requestBody ? { body: requestBody } : {}),
        signal: controller.signal,
      },
    );
  } catch (error) {
    const isTimeout = error instanceof DOMException && error.name === "AbortError";
    const code = isTimeout
      ? (params.action === "start" ? "daily_start_timeout" : "daily_stop_timeout")
      : (params.action === "start" ? "daily_start_fetch_failed" : "daily_stop_fetch_failed");
    logSafe("live_topic_hls_daily_fetch_error", {
      action: params.action,
      live_topic_id: params.liveTopicId ?? "",
      room_name_present: Boolean(params.roomName),
      error_code: code,
      timeout_ms: timeoutMs,
    });
    throw makeHlsError(code, {
      error_message: isTimeout
        ? `Daily live-streaming ${params.action} request timed out`
        : `Daily live-streaming ${params.action} request failed`,
      rtmp_url_usable: params.rtmpUrlUsable,
      playback_url_usable: params.playbackUrlUsable,
    });
  } finally {
    clearTimeout(timeoutId);
  }

  if (params.action === "start" && params.adminClient && params.liveTopicId) {
    await writeHlsDiagnostic(
      params.adminClient,
      params.liveTopicId,
      "daily_start_response_received",
      "Daily live-streaming start returned a response",
      {
        daily_status: response.status,
        rtmp_url_usable: params.rtmpUrlUsable,
        playback_url_usable: params.playbackUrlUsable,
      },
    );
  }

  const bodyText = await response.text().catch(() => "");
  let responseBody: Record<string, unknown> = {};
  if (bodyText.trim()) {
    try {
      responseBody = JSON.parse(bodyText) as Record<string, unknown>;
    } catch {
      responseBody = {};
    }
  }

  if (!response.ok) {
    logSafe("live_topic_hls_daily_response", {
      action: params.action,
      live_topic_id: params.liveTopicId ?? "",
      room_name_present: Boolean(params.roomName),
      daily_status: response.status,
      response_keys: Object.keys(responseBody),
      playback_url_present: Boolean(extractPlaybackUrl(responseBody)),
      error_code: params.action === "start"
        ? "daily_hls_start_failed"
        : "daily_hls_stop_failed",
    });
    const code = params.action === "start"
      ? "daily_start_failed"
      : "daily_hls_stop_failed";
    throw makeHlsError(code, {
      error_message: safeDailyMessage(bodyText),
      daily_status: response.status,
      daily_response_keys: Object.keys(responseBody),
      rtmp_url_usable: params.rtmpUrlUsable,
      playback_url_usable: params.playbackUrlUsable,
    });
  }

  logSafe("live_topic_hls_daily_response", {
    action: params.action,
    live_topic_id: params.liveTopicId ?? "",
    room_name_present: Boolean(params.roomName),
    daily_status: response.status,
    response_keys: Object.keys(responseBody),
    playback_url_present: Boolean(extractPlaybackUrl(responseBody)),
    sent: responseBody.sent === true || responseBody.sent === "true",
  });

  return responseBody;
}

function playbackUrlFromTemplate(template: string, topic: LiveTopicRow, roomName: string) {
  const value = template
    .replaceAll("{live_topic_id}", encodeURIComponent(topic.id))
    .replaceAll("{room_name}", encodeURIComponent(roomName));
  return extractPlaybackUrl(value);
}

async function persistHlsError(
  adminClient: SupabaseClient,
  liveTopicId: string,
  diagnostics: HlsErrorDiagnostics,
) {
  if (!isUuid(liveTopicId)) return;

  const { error } = await adminClient
    .from("live_topics")
    .update({
      hls_last_error_code: diagnostics.error_code,
      hls_last_error_message: normalizeString(diagnostics.error_message).slice(0, 160) ||
        diagnostics.error_code,
      hls_last_error_at: new Date().toISOString(),
      hls_last_daily_status: typeof diagnostics.daily_status === "number"
        ? diagnostics.daily_status
        : null,
      hls_last_daily_response_keys: diagnostics.daily_response_keys ?? [],
    })
    .eq("id", liveTopicId);

  if (error) {
    logSafe("live_topic_hls_error_persist_failed", {
      live_topic_id: liveTopicId,
      error_code: "db_update_failed",
    });
  }
}

async function writeHlsDiagnostic(
  adminClient: SupabaseClient,
  liveTopicId: string,
  code: string,
  message: string,
  extra: Partial<HlsErrorDiagnostics> = {},
) {
  try {
    await persistHlsError(adminClient, liveTopicId, {
      error_code: code,
      error_message: message,
      ...extra,
    });
  } catch {
    logSafe("live_topic_hls_diagnostic_write_failed", {
      live_topic_id: liveTopicId,
      error_code: code,
    });
  }
}

async function clearHlsError(
  adminClient: SupabaseClient,
  liveTopicId: string,
) {
  if (!isUuid(liveTopicId)) return;

  const { error } = await adminClient
    .from("live_topics")
    .update({
      hls_last_error_code: null,
      hls_last_error_message: null,
      hls_last_error_at: null,
      hls_last_daily_status: null,
      hls_last_daily_response_keys: null,
    })
    .eq("id", liveTopicId);

  if (error) {
    logSafe("live_topic_hls_error_clear_failed", {
      live_topic_id: liveTopicId,
      error_code: "db_update_failed",
    });
  }
}

async function updateTopicHls(
  adminClient: SupabaseClient,
  liveTopicId: string,
  values: Record<string, unknown>,
) {
  const { data, error } = await adminClient
    .from("live_topics")
    .update(values)
    .eq("id", liveTopicId)
    .select(
      "id,creator_user_id,cohost_user_id,status,daily_room_url,daily_room_name,ends_at,hls_playback_url,hls_status,hls_started_at,hls_ended_at",
    )
    .single();

  if (error) throw new Error("hls_status_update_failed");
  return data as LiveTopicRow;
}

serve(async (req) => {
  let diagnosticAdminClient: SupabaseClient | null = null;
  let diagnosticLiveTopicId = "";
  let diagnosticAction = "";

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  try {
    const authorization = req.headers.get("authorization") ?? "";
    if (!authorization.toLowerCase().startsWith("bearer ")) {
      throw new Error("authentication_required");
    }
    const token = authorization.replace(/^Bearer\s+/i, "").trim();
    if (!token) throw new Error("authentication_required");

    const dailyApiKey = Deno.env.get("DAILY_API_KEY")?.trim() || "";
    if (!dailyApiKey) throw new Error("daily_service_unavailable");
    const rtmpUrl = Deno.env.get("LIVE_TOPIC_HLS_RTMP_URL")?.trim() || "";
    const playbackUrlTemplate =
      Deno.env.get("LIVE_TOPIC_HLS_PLAYBACK_URL")?.trim() ||
      Deno.env.get("LIVE_TOPIC_HLS_PLAYBACK_URL_TEMPLATE")?.trim() ||
      "";

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const { data: authData, error: authError } = await callerClient.auth.getUser();
    if (authError || !authData.user) throw new Error("authentication_required");

    const body = await req.json().catch(() => ({}));
    const liveTopicId = normalizeString(body?.live_topic_id);
    const action = normalizeString(body?.action).toLowerCase();
    diagnosticAdminClient = adminClient;
    diagnosticLiveTopicId = liveTopicId;
    diagnosticAction = action;

    if (!liveTopicId) throw makeHlsError("missing_live_topic_id");
    if (!isUuid(liveTopicId)) throw makeHlsError("invalid_live_topic");
    if (!["start", "stop", "status"].includes(action)) {
      throw new Error("invalid_action");
    }

    if (action === "start") {
      await writeHlsDiagnostic(
        adminClient,
        liveTopicId,
        "hls_start_received",
        "HLS start request received by Edge Function",
      );
    }

    const topic = await fetchLiveTopic(adminClient, liveTopicId);
    const callerUserId = authData.user.id;
    const isHostOrCohost =
      topic.creator_user_id === callerUserId || topic.cohost_user_id === callerUserId;
    const hasViewerAccess = action === "start" && !isHostOrCohost
      ? await userHasLiveTopicViewerAccess(adminClient, liveTopicId, callerUserId)
      : false;
    logSafe("live_topic_hls_request", {
      action,
      live_topic_id: liveTopicId,
      authorized: isHostOrCohost || hasViewerAccess,
      authorized_as_viewer: hasViewerAccess,
      room_name_present: Boolean(topic.daily_room_name),
      room_url_present: Boolean(topic.daily_room_url),
      hls_status: topic.hls_status ?? "not_started",
    });
    if (!isHostOrCohost && !hasViewerAccess) {
      const error = makeHlsError("unauthorized_user");
      await persistHlsError(adminClient, liveTopicId, safeErrorDiagnostics(error));
      throw error;
    }

    if (action === "status") {
      return jsonResponse({
        success: true,
        live_topic_id: topic.id,
        hls_status: topic.hls_status ?? "not_started",
        hls_playback_url: topic.hls_playback_url ?? "",
      });
    }

    if (topic.status === "ended" || topic.status === "cancelled" || topic.status === "declined") {
      if (action === "stop") {
        const updated = await updateTopicHls(adminClient, liveTopicId, {
          hls_status: "ended",
          hls_ended_at: new Date().toISOString(),
        });
        return jsonResponse({
          success: true,
          live_topic_id: updated.id,
          hls_status: updated.hls_status ?? "ended",
          hls_playback_url: updated.hls_playback_url ?? "",
          stopped: true,
          already_ended: true,
        });
      }
      throw new Error("topic_ended");
    }

    if (topic.status !== "live") throw new Error("topic_not_live");

    if (action === "start") {
      const roomAccess = await ensureDailyRoom({ adminClient, dailyApiKey, topic });
      let roomName = "";
      try {
        roomName = resolveRoomName(roomAccess.topic);
      } catch {
        const error = makeHlsError("missing_daily_room_name");
        await persistHlsError(adminClient, liveTopicId, safeErrorDiagnostics(error));
        throw error;
      }
      if (!rtmpUrl || !playbackUrlTemplate) {
        logSafe("live_topic_hls_missing_output_config", {
          action,
          live_topic_id: liveTopicId,
          room_name_present: Boolean(roomName),
          rtmp_url_configured: Boolean(rtmpUrl),
          playback_url_configured: Boolean(playbackUrlTemplate),
          error_code: "daily_hls_output_not_configured",
        });
        await updateTopicHls(adminClient, liveTopicId, {
          hls_status: "failed",
          hls_ended_at: null,
        });
        const error = makeHlsError("daily_hls_output_not_configured", {
          rtmp_url_usable: Boolean(rtmpUrl),
          playback_url_usable: Boolean(playbackUrlTemplate),
        });
        await persistHlsError(adminClient, liveTopicId, safeErrorDiagnostics(error));
        throw error;
      }
      const rtmpUrlUsable = rtmpUrlLooksUsable(rtmpUrl);
      const playbackUrlUsable = playbackUrlLooksUsable(playbackUrlTemplate);
      if (!rtmpUrlUsable || !playbackUrlUsable) {
        logSafe("live_topic_hls_invalid_output_config", {
          action,
          live_topic_id: liveTopicId,
          room_name_present: Boolean(roomName),
          rtmp_url_configured: Boolean(rtmpUrl),
          rtmp_url_usable: rtmpUrlUsable,
          playback_url_configured: Boolean(playbackUrlTemplate),
          playback_url_usable: playbackUrlUsable,
          error_code: "daily_hls_output_invalid",
        });
        await updateTopicHls(adminClient, liveTopicId, {
          hls_status: "failed",
          hls_ended_at: null,
        });
        const error = makeHlsError(
          !rtmpUrlUsable ? "invalid_rtmp_config" : "invalid_playback_config",
          {
            rtmp_url_usable: rtmpUrlUsable,
            playback_url_usable: playbackUrlUsable,
          },
        );
        await persistHlsError(adminClient, liveTopicId, safeErrorDiagnostics(error));
        throw error;
      }
      if (
        roomAccess.topic.hls_status === "live" &&
        normalizeString(roomAccess.topic.hls_playback_url).length > 0
      ) {
        return jsonResponse({
          success: true,
          live_topic_id: roomAccess.topic.id,
          hls_status: roomAccess.topic.hls_status,
          hls_playback_url: roomAccess.topic.hls_playback_url,
          already_started: true,
        });
      }

      await writeHlsDiagnostic(
        adminClient,
        liveTopicId,
        "hls_start_validated",
        "HLS start validation passed; preparing Daily start request",
        {
          rtmp_url_usable: true,
          playback_url_usable: true,
        },
      );

      await updateTopicHls(adminClient, liveTopicId, {
        hls_status: "pending",
        hls_ended_at: null,
      });
      await writeHlsDiagnostic(
        adminClient,
        liveTopicId,
        "daily_start_in_progress",
        "Calling Daily live-streaming start endpoint",
        {
          rtmp_url_usable: true,
          playback_url_usable: true,
        },
      );
      logSafe("live_topic_hls_daily_request", {
        action,
        live_topic_id: liveTopicId,
        room_name_present: Boolean(roomName),
        rtmp_url_configured: true,
        rtmp_url_usable: true,
        playback_url_configured: true,
        playback_url_usable: true,
      });

      try {
        const dailyBody = await callDailyLiveStreaming({
          dailyApiKey,
          roomName,
          action: "start",
          rtmpUrl,
          liveTopicId,
          adminClient,
          rtmpUrlUsable,
          playbackUrlUsable,
        });
        const playbackUrl = extractPlaybackUrl(dailyBody) ||
          playbackUrlFromTemplate(playbackUrlTemplate, roomAccess.topic, roomName);
        if (!playbackUrl) {
          throw makeHlsError("daily_response_unexpected", {
            error_message: "Daily accepted start but no configured playback URL was usable.",
            daily_response_keys: Object.keys(dailyBody),
            rtmp_url_usable: true,
            playback_url_usable: false,
          });
        }
        const updated = await updateTopicHls(adminClient, liveTopicId, {
          hls_status: "live",
          hls_playback_url: playbackUrl,
          hls_started_at: new Date().toISOString(),
          hls_ended_at: null,
        });
        if (
          (updated.hls_status ?? "") === "pending" &&
          !normalizeString(updated.hls_playback_url)
        ) {
          await updateTopicHls(adminClient, liveTopicId, {
            hls_status: "failed",
            hls_ended_at: null,
          });
          const error = makeHlsError("hls_start_exited_while_pending", {
            error_message: "HLS start path exited while still pending without playback URL",
            rtmp_url_usable: true,
            playback_url_usable: true,
          });
          await persistHlsError(adminClient, liveTopicId, safeErrorDiagnostics(error));
          throw error;
        }
        await clearHlsError(adminClient, liveTopicId);
        return jsonResponse({
          success: true,
          live_topic_id: updated.id,
          hls_status: updated.hls_status ?? "pending",
          hls_playback_url: updated.hls_playback_url ?? "",
          playback_url_available: Boolean(playbackUrl),
        });
      } catch (error) {
        const diagnostics = safeErrorDiagnostics(error);
        await updateTopicHls(adminClient, liveTopicId, {
          hls_status: "failed",
          hls_ended_at: null,
        });
        await persistHlsError(adminClient, liveTopicId, diagnostics);
        throw error;
      }
    }

    let roomName = "";
    try {
      roomName = resolveRoomName(topic);
    } catch {
      const updated = await updateTopicHls(adminClient, liveTopicId, {
        hls_status: "ended",
        hls_ended_at: new Date().toISOString(),
      });
      return jsonResponse({
        success: true,
        live_topic_id: updated.id,
        hls_status: updated.hls_status ?? "ended",
        hls_playback_url: updated.hls_playback_url ?? "",
        stopped: true,
        room_missing: true,
      });
    }

    try {
      await callDailyLiveStreaming({
        dailyApiKey,
        roomName,
        action: "stop",
        liveTopicId,
      });
    } catch (error) {
      const text = error instanceof Error ? error.message : String(error ?? "");
      if (!text.includes("404") && !text.includes("not_found")) throw error;
    }

    const updated = await updateTopicHls(adminClient, liveTopicId, {
      hls_status: "ended",
      hls_ended_at: new Date().toISOString(),
    });
    return jsonResponse({
      success: true,
      live_topic_id: updated.id,
      hls_status: updated.hls_status ?? "ended",
      hls_playback_url: updated.hls_playback_url ?? "",
      stopped: true,
    });
  } catch (error) {
    const diagnostics = safeErrorDiagnostics(error);
    if (
      diagnosticAdminClient &&
      diagnosticAction === "start" &&
      isUuid(diagnosticLiveTopicId)
    ) {
      try {
        await updateTopicHls(diagnosticAdminClient, diagnosticLiveTopicId, {
          hls_status: "failed",
          hls_ended_at: null,
        });
      } catch {
        logSafe("live_topic_hls_final_status_persist_failed", {
          live_topic_id: diagnosticLiveTopicId,
          error_code: "db_update_failed",
        });
      }

      await persistHlsError(
        diagnosticAdminClient,
        diagnosticLiveTopicId,
        diagnostics,
      );
    }

    return jsonResponse({
      ok: false,
      error: diagnostics.error_code,
      error_code: diagnostics.error_code,
      message: safeErrorMessage(error),
      rtmp_url_usable: diagnostics.rtmp_url_usable,
      playback_url_usable: diagnostics.playback_url_usable,
      daily_status: diagnostics.daily_status,
      daily_response_keys: diagnostics.daily_response_keys,
    }, 400);
  }
});
