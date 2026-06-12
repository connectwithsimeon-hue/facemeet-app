import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  buildRewardEmailHtml,
  sendTransactionalEmail,
} from "../_shared/email.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const CTA_URL = "https://app.facemeet.app";
const SENDER = "FaceMeet <support@facemeet.app>";
const ALLOWED_ACTIONS = new Set(["preview", "send"]);
const ALLOWED_TEMPLATES = new Set([
  "upload_video",
  "complete_profile",
  "complete_profile_for_event",
]);
const ALLOWED_SOURCE_CONTEXTS = new Set(["Users Directory", "Events Roster"]);
const COOLDOWN_MS = 24 * 60 * 60 * 1000;

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

function safeErrorMessage(error: unknown) {
  const text = error instanceof Error ? error.message : String(error ?? "");
  if (
    text.includes("admin access required") || text.includes("missing_authorization") ||
    text.includes("invalid_authorization")
  ) {
    return "admin access required";
  }
  return "Email delivery is temporarily unavailable. Please try again later.";
}

function buildTemplate(template: string, firstName: string) {
  switch (template) {
    case "upload_video": {
      const subject = "Please upload your FaceMeet video profile";
      const paragraphs = [
        `Hi ${firstName},`,
        "Your FaceMeet profile is almost ready. Please upload your video profile so your account can be fully reviewed in the app.",
        "Open FaceMeet, go to your Profile, and add your video when you’re ready.",
        "If you need help, reply to this email and our team can assist.",
        "FaceMeet Support",
      ];
      return {
        subject,
        text: paragraphs.join("\n\n"),
        html: buildRewardEmailHtml({
          eyebrow: "FaceMeet",
          title: subject,
          paragraphs,
          ctaLabel: "Open FaceMeet",
          ctaUrl: CTA_URL,
          footer: "FaceMeet Support",
        }),
      };
    }
    case "complete_profile": {
      const subject = "Please complete your FaceMeet profile";
      const paragraphs = [
        `Hi ${firstName},`,
        "We noticed that your FaceMeet profile is still missing some required information.",
        "Please open FaceMeet and complete your profile so your account is ready for the full experience.",
        "If you need help, reply to this email and our team can assist.",
        "FaceMeet Support",
      ];
      return {
        subject,
        text: paragraphs.join("\n\n"),
        html: buildRewardEmailHtml({
          eyebrow: "FaceMeet",
          title: subject,
          paragraphs,
          ctaLabel: "Open FaceMeet",
          ctaUrl: CTA_URL,
          footer: "FaceMeet Support",
        }),
      };
    }
    case "complete_profile_for_event": {
      const subject =
        "Please complete your FaceMeet profile before event approval";
      const paragraphs = [
        `Hi ${firstName},`,
        "Before we can fully review your event access, we need a complete FaceMeet profile on file.",
        "Please open FaceMeet and complete your profile, including your video profile if it is still missing.",
        "Once that is done, your profile will be ready for event review.",
        "If you need help, reply to this email and our team can assist.",
        "FaceMeet Support",
      ];
      return {
        subject,
        text: paragraphs.join("\n\n"),
        html: buildRewardEmailHtml({
          eyebrow: "FaceMeet Events",
          title: subject,
          paragraphs,
          ctaLabel: "Open FaceMeet",
          ctaUrl: CTA_URL,
          footer: "FaceMeet Support",
        }),
      };
    }
    default:
      return null;
  }
}

async function getCooldownState(params: {
  adminClient: ReturnType<typeof createClient>;
  userId: string;
  template: string;
}) {
  const windowStart = new Date(Date.now() - COOLDOWN_MS).toISOString();
  const { data, error } = await params.adminClient
    .from("admin_audit_logs")
    .select("created_at")
    .eq("action", "send_profile_completion_reminder")
    .eq("target_type", "user")
    .eq("target_id", params.userId)
    .contains("metadata", { template: params.template })
    .gte("created_at", windowStart)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) {
    throw new Error("cooldown_lookup_failed");
  }

  if (!data?.created_at) {
    return {
      cooldownActive: false,
      cooldownExpiresAt: null as string | null,
    };
  }

  const createdAtMs = new Date(data.created_at).getTime();
  const expiresAtMs = createdAtMs + COOLDOWN_MS;
  const cooldownActive = expiresAtMs > Date.now();

  return {
    cooldownActive,
    cooldownExpiresAt: new Date(expiresAtMs).toISOString(),
  };
}

async function writeReminderAuditLog(params: {
  callerClient: ReturnType<typeof createClient>;
  adminClient: ReturnType<typeof createClient>;
  adminUserId: string;
  userId: string;
  template: string;
  recipientEmail: string;
  sourceContext: string;
  eventId: string | null;
}) {
  const metadata = {
    template: params.template,
    email: params.recipientEmail,
    source_context: params.sourceContext,
    event_id: params.eventId,
    delivery_channel: "email",
    cta_url: CTA_URL,
  };

  const rpcResult = await params.callerClient.rpc("log_admin_action", {
    p_action: "send_profile_completion_reminder",
    p_target_type: "user",
    p_target_id: params.userId,
    p_metadata: metadata,
  });

  if (!rpcResult.error) {
    return { success: true as const, method: "rpc" as const };
  }

  console.error("PROFILE REMINDER: rpc audit log failed", {
    message: rpcResult.error.message,
  });

  const insertResult = await params.adminClient
    .from("admin_audit_logs")
    .insert({
      admin_user_id: params.adminUserId,
      action: "send_profile_completion_reminder",
      target_type: "user",
      target_id: params.userId,
      metadata,
    });

  if (!insertResult.error) {
    return { success: true as const, method: "insert" as const };
  }

  console.error("PROFILE REMINDER: fallback audit log failed", {
    message: insertResult.error.message,
  });

  return { success: false as const };
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
    const userId = normalizeString(body.user_id);
    const template = normalizeString(body.template);
    const sourceContext = normalizeString(body.source_context);
    const eventId = normalizeString(body.event_id);

    if (!ALLOWED_ACTIONS.has(action)) {
      return jsonResponse({ error: "invalid action" }, 400);
    }

    if (!ALLOWED_TEMPLATES.has(template)) {
      return jsonResponse({ error: "invalid template" }, 400);
    }

    if (!ALLOWED_SOURCE_CONTEXTS.has(sourceContext)) {
      return jsonResponse({ error: "invalid source context" }, 400);
    }

    if (!isUuid(userId)) {
      return jsonResponse({ error: "member not found" }, 404);
    }

    if (eventId && !isUuid(eventId)) {
      return jsonResponse({ error: "invalid event id" }, 400);
    }

    const { data: member, error: memberError } = await adminClient
      .from("users")
      .select("id,email,first_name")
      .eq("id", userId)
      .maybeSingle();

    if (memberError) {
      return jsonResponse({ error: "Email delivery is temporarily unavailable. Please try again later." }, 500);
    }

    if (!member) {
      return jsonResponse({ error: "member not found" }, 404);
    }

    const recipientEmail = normalizeString(member.email);
    if (!recipientEmail || !isValidEmail(recipientEmail)) {
      return jsonResponse({
        error: "This member does not have a usable email address.",
      }, 400);
    }

    const greetingName = safeFirstName(member.first_name);
    const rendered = buildTemplate(template, greetingName);
    if (!rendered) {
      return jsonResponse({ error: "invalid template" }, 400);
    }

    const safeEventId = template === "complete_profile_for_event" && eventId
      ? eventId
      : null;

    const cooldown = await getCooldownState({
      adminClient,
      userId,
      template,
    });

    if (action === "preview") {
      return jsonResponse({
        success: true,
        action: "preview",
        template,
        recipient_email: recipientEmail,
        subject: rendered.subject,
        text: rendered.text,
        html: rendered.html,
        cta_url: CTA_URL,
        cooldown_active: cooldown.cooldownActive,
        cooldown_expires_at: cooldown.cooldownExpiresAt,
      });
    }

    if (cooldown.cooldownActive) {
      return jsonResponse({
        error:
          "A reminder for this template was sent recently. Try again later.",
        cooldown_expires_at: cooldown.cooldownExpiresAt,
      }, 429);
    }

    const emailResult = await sendTransactionalEmail({
      from: SENDER,
      to: recipientEmail,
      subject: rendered.subject,
      text: rendered.text,
      html: rendered.html,
    });

    if (!emailResult.success) {
      return jsonResponse({
        error: "Email delivery is temporarily unavailable. Please try again later.",
      }, 503);
    }

    const auditResult = await writeReminderAuditLog({
      callerClient,
      adminClient,
      adminUserId: adminIdResult.data,
      userId,
      template,
      recipientEmail,
      sourceContext,
      eventId: safeEventId,
    });

    if (!auditResult.success) {
      return jsonResponse({
        error:
          "Reminder sent, but cooldown tracking failed. Please do not resend yet and contact support.",
      }, 500);
    }

    return jsonResponse({
      success: true,
      action: "send",
      message: "Reminder sent.",
    });
  } catch (error) {
    console.error("PROFILE REMINDER: unexpected error", {
      message: error instanceof Error ? error.message : "unknown_error",
    });
    return jsonResponse({ error: safeErrorMessage(error) }, 500);
  }
});
