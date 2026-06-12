import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  buildRewardEmailHtml,
  sendTransactionalEmail,
} from "../_shared/email.ts";
import { sendWebPushToUser } from "../_shared/web_push.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const CTA_URL = "https://app.facemeet.app";
const SOURCE_CONTEXT = "Events HQ";
const EMAIL_SENDER = "FaceMeet <support@facemeet.app>";
const COOLDOWN_MS = 24 * 60 * 60 * 1000;

const ALLOWED_ACTIONS = new Set(["preview", "dry_run", "send"]);
const ALLOWED_TEMPLATES = new Set([
  "pairing_preferences_open",
  "pairing_preferences_closing_soon",
  "pair_ticket_released",
  "event_tomorrow",
]);
const ALLOWED_CHANNELS = new Set(["email", "push"]);

type SupabaseClient = ReturnType<typeof createClient>;
type ReminderTemplate =
  | "pairing_preferences_open"
  | "pairing_preferences_closing_soon"
  | "pair_ticket_released"
  | "event_tomorrow";
type ReminderChannel = "email" | "push";

type EventRecord = {
  id: string;
  title: string;
  pairing_preferences_status: string | null;
  status: string;
  starts_at: string;
};

type UserRecord = {
  id: string;
  email: string | null;
  first_name: string | null;
};

type RsvpRecord = {
  event_id: string;
  user_id: string;
  status: string;
  pairing_released_at: string | null;
};

type RecipientRecord = {
  userId: string;
  firstName: string;
  email: string;
  rsvp: RsvpRecord;
};

type RenderedReminder = {
  emailSubject: string;
  emailText: string;
  emailHtml: string;
  pushTitle: string;
  pushBody: string;
};

type PushReachability = {
  native: boolean;
  web: boolean;
  available: boolean;
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

function isValidEmail(value: string) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function safeFirstName(value: unknown) {
  const firstName = normalizeString(value);
  return firstName || "there";
}

function uniqueChannels(channels: unknown): ReminderChannel[] {
  if (!Array.isArray(channels)) {
    return [];
  }

  const normalized = channels
    .map((value) => normalizeString(value))
    .filter((value): value is ReminderChannel =>
      ALLOWED_CHANNELS.has(value as ReminderChannel)
    );

  return Array.from(new Set(normalized));
}

function invalidChannelRequested(channels: unknown) {
  if (!Array.isArray(channels) || channels.length === 0) {
    return true;
  }

  return channels.some((value) => !ALLOWED_CHANNELS.has(normalizeString(value)));
}

function buildTemplate(
  template: ReminderTemplate,
  firstName: string,
  eventTitle: string,
): RenderedReminder {
  switch (template) {
    case "pairing_preferences_open": {
      const subject = "Pairing Preferences are open for your FaceMeet event";
      const paragraphs = [
        `Hi ${firstName},`,
        `Pairing Preferences are now open for ${eventTitle}.`,
        "Open FaceMeet and tell us how you would like to attend. You can select an existing Match, choose Open to a New Introduction, or request Open Social Access.",
        "Please submit your preferences before the window closes.",
        "FaceMeet Support",
      ];
      return {
        emailSubject: subject,
        emailText: paragraphs.join("\n\n"),
        emailHtml: buildRewardEmailHtml({
          eyebrow: "FaceMeet Events",
          title: subject,
          paragraphs,
          ctaLabel: "Open FaceMeet",
          ctaUrl: CTA_URL,
          footer: "FaceMeet Support",
        }),
        pushTitle: "Pairing Preferences are open",
        pushBody: `Tell us how you would like to attend ${eventTitle}.`,
      };
    }
    case "pairing_preferences_closing_soon": {
      const subject =
        "Pairing Preferences are closing soon for your FaceMeet event";
      const paragraphs = [
        `Hi ${firstName},`,
        `Pairing Preferences for ${eventTitle} are closing soon.`,
        "Open FaceMeet and submit or update your attendance preferences before the window closes.",
        "FaceMeet Support",
      ];
      return {
        emailSubject: subject,
        emailText: paragraphs.join("\n\n"),
        emailHtml: buildRewardEmailHtml({
          eyebrow: "FaceMeet Events",
          title: subject,
          paragraphs,
          ctaLabel: "Open FaceMeet",
          ctaUrl: CTA_URL,
          footer: "FaceMeet Support",
        }),
        pushTitle: "Pairing Preferences are closing soon",
        pushBody: `Submit or update your preferences for ${eventTitle}.`,
      };
    }
    case "pair_ticket_released": {
      const subject = "Your FaceMeet Pair Ticket is ready";
      const paragraphs = [
        `Hi ${firstName},`,
        `Your Pair Ticket for ${eventTitle} is ready.`,
        "Open FaceMeet to view your event-access details and Pair Check-In information.",
        "FaceMeet Support",
      ];
      return {
        emailSubject: subject,
        emailText: paragraphs.join("\n\n"),
        emailHtml: buildRewardEmailHtml({
          eyebrow: "FaceMeet Events",
          title: subject,
          paragraphs,
          ctaLabel: "Open FaceMeet",
          ctaUrl: CTA_URL,
          footer: "FaceMeet Support",
        }),
        pushTitle: "Your Pair Ticket is ready",
        pushBody: `Open FaceMeet to view your Pair Ticket for ${eventTitle}.`,
      };
    }
    case "event_tomorrow": {
      const subject = "Your FaceMeet event is tomorrow";
      const paragraphs = [
        `Hi ${firstName},`,
        `${eventTitle} is tomorrow.`,
        "Open FaceMeet to review your event details and access information before you arrive.",
        "We look forward to seeing you.",
        "FaceMeet Support",
      ];
      return {
        emailSubject: subject,
        emailText: paragraphs.join("\n\n"),
        emailHtml: buildRewardEmailHtml({
          eyebrow: "FaceMeet Events",
          title: subject,
          paragraphs,
          ctaLabel: "Open FaceMeet",
          ctaUrl: CTA_URL,
          footer: "FaceMeet Support",
        }),
        pushTitle: "Your FaceMeet event is tomorrow",
        pushBody: `Review your event details before ${eventTitle}.`,
      };
    }
  }
}

function isRecipientEligibleForTemplate(
  template: ReminderTemplate,
  event: EventRecord,
  rsvp: RsvpRecord,
) {
  if (rsvp.status !== "approved") {
    return { eligible: false, reason: "rsvp_not_approved" };
  }

  switch (template) {
    case "pairing_preferences_open":
    case "pairing_preferences_closing_soon":
      if (event.pairing_preferences_status !== "open") {
        return { eligible: false, reason: "pairing_preferences_not_open" };
      }
      if (rsvp.pairing_released_at) {
        return { eligible: false, reason: "pairing_ticket_already_released" };
      }
      return { eligible: true, reason: null };
    case "pair_ticket_released":
      if (!rsvp.pairing_released_at) {
        return { eligible: false, reason: "pair_ticket_not_released" };
      }
      return { eligible: true, reason: null };
    case "event_tomorrow":
      return { eligible: true, reason: null };
  }
}

function safeErrorMessage(error: unknown) {
  const text = error instanceof Error ? error.message : String(error ?? "");

  if (
    text.includes("admin access required") || text.includes("missing_authorization") ||
    text.includes("invalid_authorization")
  ) {
    return "admin access required";
  }
  if (text.includes("invalid action")) return "invalid action";
  if (text.includes("invalid event")) return "invalid event";
  if (text.includes("invalid user")) return "invalid user";
  if (text.includes("invalid template")) return "invalid template";
  if (text.includes("invalid channel")) return "invalid channel";
  if (text.includes("event not found")) return "event not found";
  if (text.includes("attendee not found")) return "attendee not found";
  if (text.includes("no eligible recipients")) return "no eligible recipients";
  if (text.includes("delivery channel unavailable")) {
    return "delivery channel unavailable";
  }
  if (text.includes("cooldown_active")) {
    return "A reminder for this event, template, and channel was sent recently.";
  }
  if (text.includes("email_delivery_unavailable")) {
    return "Email delivery is temporarily unavailable. Please try again later.";
  }
  if (text.includes("push_delivery_unavailable")) {
    return "Push delivery is temporarily unavailable. Please try again later.";
  }
  if (text.includes("tracked_delivery_failed")) {
    return "Push delivery is temporarily unavailable. Please try again later.";
  }

  return "Push delivery is temporarily unavailable. Please try again later.";
}

async function fetchEvent(adminClient: SupabaseClient, eventId: string) {
  const { data, error } = await adminClient
    .from("events")
    .select("id,title,pairing_preferences_status,status,starts_at")
    .eq("id", eventId)
    .maybeSingle();

  if (error) throw new Error("event_lookup_failed");
  if (!data) throw new Error("event not found");
  return data as EventRecord;
}

async function fetchApprovedRsvp(
  adminClient: SupabaseClient,
  eventId: string,
  userId: string,
) {
  const { data, error } = await adminClient
    .from("event_rsvps")
    .select("event_id,user_id,status,pairing_released_at")
    .eq("event_id", eventId)
    .eq("user_id", userId)
    .eq("status", "approved")
    .maybeSingle();

  if (error) throw new Error("rsvp_lookup_failed");
  if (!data) throw new Error("attendee not found");
  return data as RsvpRecord;
}

async function fetchApprovedRsvpsForEvent(
  adminClient: SupabaseClient,
  eventId: string,
) {
  const { data, error } = await adminClient
    .from("event_rsvps")
    .select("event_id,user_id,status,pairing_released_at")
    .eq("event_id", eventId)
    .eq("status", "approved");

  if (error) throw new Error("rsvp_lookup_failed");
  return (data ?? []) as RsvpRecord[];
}

async function fetchUsersByIds(adminClient: SupabaseClient, userIds: string[]) {
  if (userIds.length === 0) return new Map<string, UserRecord>();

  const { data, error } = await adminClient
    .from("users")
    .select("id,email,first_name")
    .in("id", userIds);

  if (error) throw new Error("user_lookup_failed");

  return new Map(
    ((data ?? []) as UserRecord[]).map((user) => [user.id, user]),
  );
}

async function fetchNativePushUserIds(
  adminClient: SupabaseClient,
  userIds: string[],
) {
  if (userIds.length === 0) return new Set<string>();

  const { data, error } = await adminClient
    .from("device_tokens")
    .select("user_id")
    .in("user_id", userIds)
    .eq("notifications_enabled", true);

  if (error) throw new Error("native_push_lookup_failed");

  return new Set((data ?? []).map((row: { user_id: string }) => row.user_id));
}

async function fetchWebPushUserIds(
  adminClient: SupabaseClient,
  userIds: string[],
) {
  if (userIds.length === 0) return new Set<string>();

  const { data, error } = await adminClient
    .from("web_push_subscriptions")
    .select("user_id")
    .in("user_id", userIds)
    .eq("is_active", true);

  if (error) throw new Error("web_push_lookup_failed");

  return new Set((data ?? []).map((row: { user_id: string }) => row.user_id));
}

function hasWebPushConfig() {
  return Boolean(
    Deno.env.get("VAPID_SUBJECT") && Deno.env.get("VAPID_PUBLIC_KEY") &&
      Deno.env.get("VAPID_PRIVATE_KEY"),
  );
}

function hasNativePushConfig() {
  return Boolean(
    Deno.env.get("FIREBASE_SERVICE_ACCOUNT") && Deno.env.get("FIREBASE_PROJECT_ID"),
  );
}

async function getRecipientReachability(params: {
  adminClient: SupabaseClient;
  userId: string;
  email: string;
}) {
  const [nativeUsers, webUsers] = await Promise.all([
    hasNativePushConfig()
      ? fetchNativePushUserIds(params.adminClient, [params.userId])
      : Promise.resolve(new Set<string>()),
    hasWebPushConfig()
      ? fetchWebPushUserIds(params.adminClient, [params.userId])
      : Promise.resolve(new Set<string>()),
  ]);

  const native = nativeUsers.has(params.userId);
  const web = webUsers.has(params.userId);

  return {
    emailAvailable: Boolean(params.email && isValidEmail(params.email)),
    push: {
      native,
      web,
      available: native || web,
    } satisfies PushReachability,
  };
}

async function getCooldownState(params: {
  adminClient: SupabaseClient;
  eventId: string;
  userId: string;
  template: ReminderTemplate;
  channel: ReminderChannel;
}) {
  const windowStart = new Date(Date.now() - COOLDOWN_MS).toISOString();
  const { data, error } = await params.adminClient
    .from("admin_audit_logs")
    .select("created_at")
    .eq("action", "send_event_reminder")
    .eq("target_type", "user")
    .eq("target_id", params.userId)
    .contains("metadata", {
      event_id: params.eventId,
      template: params.template,
      delivery_channel: params.channel,
    })
    .gte("created_at", windowStart)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) throw new Error("cooldown_lookup_failed");

  if (!data?.created_at) {
    return { active: false, expiresAt: null as string | null };
  }

  const createdAtMs = new Date(data.created_at).getTime();
  const expiresAtMs = createdAtMs + COOLDOWN_MS;
  const active = expiresAtMs > Date.now();

  return {
    active,
    expiresAt: active ? new Date(expiresAtMs).toISOString() : null,
  };
}

async function writeReminderAuditLog(params: {
  callerClient: SupabaseClient;
  adminClient: SupabaseClient;
  adminUserId: string;
  eventId: string;
  userId: string;
  template: ReminderTemplate;
  channel: ReminderChannel;
  recipientEmail: string | null;
}) {
  const metadata: Record<string, unknown> = {
    event_id: params.eventId,
    template: params.template,
    delivery_channel: params.channel,
    cta_url: CTA_URL,
    source_context: SOURCE_CONTEXT,
  };

  if (params.recipientEmail) {
    metadata.email = params.recipientEmail;
  }

  const rpcResult = await params.callerClient.rpc("log_admin_action", {
    p_action: "send_event_reminder",
    p_target_type: "user",
    p_target_id: params.userId,
    p_metadata: metadata,
  });

  if (!rpcResult.error) {
    return { success: true as const, method: "rpc" as const };
  }

  console.error("EVENT REMINDER: rpc audit log failed", {
    message: rpcResult.error.message,
  });

  const insertResult = await params.adminClient
    .from("admin_audit_logs")
    .insert({
      admin_user_id: params.adminUserId,
      action: "send_event_reminder",
      target_type: "user",
      target_id: params.userId,
      metadata,
    });

  if (!insertResult.error) {
    return { success: true as const, method: "insert" as const };
  }

  console.error("EVENT REMINDER: fallback audit log failed", {
    message: insertResult.error.message,
  });

  return { success: false as const };
}

async function getFirebaseToken(serviceAccount: Record<string, string>) {
  const now = Math.floor(Date.now() / 1000);

  const header = btoa(JSON.stringify({ alg: "RS256", typ: "JWT" }))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const payload = btoa(JSON.stringify({
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  })).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const signingInput = `${header}.${payload}`;
  const pemKey = serviceAccount.private_key;
  const pemContent = pemKey
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const binaryKey = Uint8Array.from(atob(pemContent), (char) =>
    char.charCodeAt(0)
  );

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );

  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const jwt = `${signingInput}.${sigB64}`;
  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body:
      `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });
  const tokenData = await tokenRes.json();

  if (!tokenData.access_token) {
    throw new Error("native_push_auth_failed");
  }

  return tokenData.access_token as string;
}

async function sendNativePushToUser(params: {
  adminClient: SupabaseClient;
  userId: string;
  type: string;
  title: string;
  body: string;
  data: Record<string, string>;
}) {
  if (!hasNativePushConfig()) {
    return { sent: 0 };
  }

  const { data: tokens, error } = await params.adminClient
    .from("device_tokens")
    .select("fcm_token")
    .eq("user_id", params.userId)
    .eq("notifications_enabled", true);

  if (error) {
    throw new Error("native_push_lookup_failed");
  }

  if (!tokens?.length) {
    return { sent: 0 };
  }

  const serviceAccount = JSON.parse(Deno.env.get("FIREBASE_SERVICE_ACCOUNT")!);
  const projectId = Deno.env.get("FIREBASE_PROJECT_ID")!;
  const accessToken = await getFirebaseToken(serviceAccount);

  let sent = 0;
  const stringData: Record<string, string> = {
    type: String(params.type || ""),
    ...Object.fromEntries(
      Object.entries(params.data || {}).map(([key, value]) => [
        key,
        String(value ?? ""),
      ]),
    ),
  };

  for (const { fcm_token } of tokens as Array<{ fcm_token: string }>) {
    try {
      const fcmRes = await fetch(
        `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              token: fcm_token,
              notification: {
                title: params.title || "FaceMeet",
                body: params.body || "",
              },
              data: stringData,
              android: {
                priority: "high",
                notification: {
                  channel_id: "facemeet_notifications",
                  sound: "default",
                },
              },
              apns: {
                headers: {
                  "apns-priority": "10",
                  "apns-push-type": "alert",
                },
                payload: {
                  aps: {
                    sound: "default",
                    badge: 1,
                  },
                },
              },
            },
          }),
        },
      );

      const fcmData = await fcmRes.json();

      if (fcmRes.ok) {
        sent += 1;
      } else if (fcmData.error?.details?.[0]?.errorCode === "UNREGISTERED") {
        await params.adminClient.from("device_tokens").delete().eq(
          "fcm_token",
          fcm_token,
        );
      }
    } catch (_error) {
      // Keep trying other tokens for this user.
    }
  }

  return { sent };
}

async function sendPushToUser(params: {
  adminClient: SupabaseClient;
  userId: string;
  template: ReminderTemplate;
  eventId: string;
  title: string;
  body: string;
}) {
  const payload = {
    event_id: params.eventId,
    cta_url: CTA_URL,
    template: params.template,
  };

  const [nativeResult, webResult] = await Promise.all([
    sendNativePushToUser({
      adminClient: params.adminClient,
      userId: params.userId,
      type: params.template,
      title: params.title,
      body: params.body,
      data: payload,
    }),
    hasWebPushConfig()
      ? sendWebPushToUser({
        adminClient: params.adminClient,
        userId: params.userId,
        type: params.template,
        title: params.title,
        body: params.body,
        data: payload,
      })
      : Promise.resolve({ sent: 0 }),
  ]);

  return {
    sent: (nativeResult.sent ?? 0) + (webResult.sent ?? 0),
    nativeSent: nativeResult.sent ?? 0,
    webSent: webResult.sent ?? 0,
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
    const token = authorization.replace(/^Bearer\s+/i, "").trim();

    if (!token) {
      return jsonResponse({ error: "admin access required" }, 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const { data: authData, error: authError } = await callerClient.auth
      .getUser();
    if (authError || !authData?.user) {
      return jsonResponse({ error: "admin access required" }, 401);
    }

    const [adminIdResult, hasRoleResult] = await Promise.all([
      callerClient.rpc("current_admin_user_id"),
      callerClient.rpc("has_admin_role"),
    ]);

    if (
      adminIdResult.error || !adminIdResult.data || hasRoleResult.error ||
      hasRoleResult.data !== true
    ) {
      return jsonResponse({ error: "admin access required" }, 403);
    }

    const body = await req.json().catch(() => ({}));
    const action = normalizeString(body.action);
    const eventId = normalizeString(body.event_id);
    const userId = normalizeString(body.user_id);
    const template = normalizeString(body.template) as ReminderTemplate;
    const requestedChannels = uniqueChannels(body.channels);

    if (!ALLOWED_ACTIONS.has(action)) {
      return jsonResponse({ error: "invalid action" }, 400);
    }

    if (!isUuid(eventId)) {
      return jsonResponse({ error: "invalid event" }, 400);
    }

    if (action === "preview" && !isUuid(userId)) {
      return jsonResponse({ error: "invalid user" }, 400);
    }

    if (!ALLOWED_TEMPLATES.has(template)) {
      return jsonResponse({ error: "invalid template" }, 400);
    }

    if (invalidChannelRequested(body.channels) || requestedChannels.length === 0) {
      return jsonResponse({ error: "invalid channel" }, 400);
    }

    const event = await fetchEvent(adminClient, eventId);

    if (action === "preview") {
      const rsvp = await fetchApprovedRsvp(adminClient, eventId, userId);
      const eligibility = isRecipientEligibleForTemplate(template, event, rsvp);
      if (!eligibility.eligible) {
        return jsonResponse({ error: "attendee not found" }, 404);
      }

      const users = await fetchUsersByIds(adminClient, [userId]);
      const user = users.get(userId);
      if (!user) {
        return jsonResponse({ error: "attendee not found" }, 404);
      }

      const trimmedEmail = normalizeString(user.email);
      const reachability = await getRecipientReachability({
        adminClient,
        userId,
        email: trimmedEmail,
      });
      const rendered = buildTemplate(
        template,
        safeFirstName(user.first_name),
        event.title,
      );

      const cooldownEntries = await Promise.all(
        requestedChannels.map(async (channel) => ({
          channel,
          ...(await getCooldownState({
            adminClient,
            eventId,
            userId,
            template,
            channel,
          })),
        })),
      );

      const availableChannels = requestedChannels.filter((channel) => {
        if (channel === "email") return reachability.emailAvailable;
        return reachability.push.available;
      });

      return jsonResponse({
        success: true,
        action: "preview",
        event_id: eventId,
        user_id: userId,
        template,
        requested_channels: requestedChannels,
        available_channels: availableChannels,
        email_preview: requestedChannels.includes("email")
          ? {
            available: reachability.emailAvailable,
            recipient_email: reachability.emailAvailable ? trimmedEmail : null,
            subject: rendered.emailSubject,
            text: rendered.emailText,
            html: rendered.emailHtml,
          }
          : null,
        push_preview: requestedChannels.includes("push")
          ? {
            available: reachability.push.available,
            available_paths: {
              native: reachability.push.native,
              web: reachability.push.web,
            },
            title: rendered.pushTitle,
            body: rendered.pushBody,
          }
          : null,
        cta_url: CTA_URL,
        cooldown: Object.fromEntries(
          cooldownEntries.map((entry) => [
            entry.channel,
            {
              active: entry.active,
              expires_at: entry.expiresAt,
            },
          ]),
        ),
      });
    }

    const rsvps = await fetchApprovedRsvpsForEvent(adminClient, eventId);
    const eligibleRsvps: RsvpRecord[] = [];
    const exclusionReasons = new Map<string, number>();

    for (const rsvp of rsvps) {
      const eligibility = isRecipientEligibleForTemplate(template, event, rsvp);
      if (!eligibility.eligible) {
        const reason = eligibility.reason ?? "ineligible";
        exclusionReasons.set(reason, (exclusionReasons.get(reason) ?? 0) + 1);
        continue;
      }
      eligibleRsvps.push(rsvp);
    }

    const userIds = eligibleRsvps.map((rsvp) => rsvp.user_id);
    const users = await fetchUsersByIds(adminClient, userIds);
    const nativePushUsers = hasNativePushConfig()
      ? await fetchNativePushUserIds(adminClient, userIds)
      : new Set<string>();
    const webPushUsers = hasWebPushConfig()
      ? await fetchWebPushUserIds(adminClient, userIds)
      : new Set<string>();

    const recipients: RecipientRecord[] = eligibleRsvps
      .map((rsvp) => {
        const user = users.get(rsvp.user_id);
        if (!user) return null;
        return {
          userId: rsvp.user_id,
          firstName: safeFirstName(user.first_name),
          email: normalizeString(user.email),
          rsvp,
        };
      })
      .filter((value): value is RecipientRecord => value !== null);

    if (action === "dry_run") {
      const emailReachableCount = requestedChannels.includes("email")
        ? recipients.filter((recipient) => isValidEmail(recipient.email)).length
        : 0;
      const pushReachableCount = requestedChannels.includes("push")
        ? recipients.filter((recipient) =>
          nativePushUsers.has(recipient.userId) || webPushUsers.has(recipient.userId)
        ).length
        : 0;

      return jsonResponse({
        success: true,
        action: "dry_run",
        event_id: eventId,
        template,
        requested_channels: requestedChannels,
        eligible_recipient_count: recipients.length,
        email_reachable_count: emailReachableCount,
        push_reachable_count: pushReachableCount,
        excluded_count: Array.from(exclusionReasons.values()).reduce(
          (sum, count) => sum + count,
          0,
        ),
        exclusion_reasons: Object.fromEntries(exclusionReasons.entries()),
      });
    }

    if (recipients.length === 0) {
      return jsonResponse({ error: "no eligible recipients" }, 400);
    }

    let emailSentCount = 0;
    let pushSentCount = 0;
    let skippedCount = 0;

    for (const recipient of recipients) {
      const rendered = buildTemplate(template, recipient.firstName, event.title);
      const availableEmail = isValidEmail(recipient.email);
      const availablePush = nativePushUsers.has(recipient.userId) ||
        webPushUsers.has(recipient.userId);

      for (const channel of requestedChannels) {
        if (channel === "email" && !availableEmail) {
          skippedCount += 1;
          continue;
        }
        if (channel === "push" && !availablePush) {
          skippedCount += 1;
          continue;
        }

        const cooldown = await getCooldownState({
          adminClient,
          eventId,
          userId: recipient.userId,
          template,
          channel,
        });

        if (cooldown.active) {
          skippedCount += 1;
          continue;
        }

        if (channel === "email") {
          const emailResult = await sendTransactionalEmail({
            from: EMAIL_SENDER,
            to: recipient.email,
            subject: rendered.emailSubject,
            text: rendered.emailText,
            html: rendered.emailHtml,
          });

          if (!emailResult.success) {
            throw new Error("email_delivery_unavailable");
          }

          const auditResult = await writeReminderAuditLog({
            callerClient,
            adminClient,
            adminUserId: adminIdResult.data,
            eventId,
            userId: recipient.userId,
            template,
            channel: "email",
            recipientEmail: recipient.email,
          });

          if (!auditResult.success) {
            throw new Error("tracked_delivery_failed");
          }

          emailSentCount += 1;
          continue;
        }

        const pushResult = await sendPushToUser({
          adminClient,
          userId: recipient.userId,
          template,
          eventId,
          title: rendered.pushTitle,
          body: rendered.pushBody,
        });

        if (pushResult.sent <= 0) {
          throw new Error("push_delivery_unavailable");
        }

        const auditResult = await writeReminderAuditLog({
          callerClient,
          adminClient,
          adminUserId: adminIdResult.data,
          eventId,
          userId: recipient.userId,
          template,
          channel: "push",
          recipientEmail: null,
        });

        if (!auditResult.success) {
          throw new Error("tracked_delivery_failed");
        }

        pushSentCount += 1;
      }
    }

    return jsonResponse({
      success: true,
      action: "send",
      event_id: eventId,
      template,
      eligible_recipient_count: recipients.length,
      email_sent_count: emailSentCount,
      push_sent_count: pushSentCount,
      skipped_count: skippedCount,
      message: "Event reminders sent.",
    });
  } catch (error) {
    console.error("EVENT REMINDER: unexpected error", {
      message: error instanceof Error ? error.message : "unknown_error",
    });
    return jsonResponse({ error: safeErrorMessage(error) }, 500);
  }
});
