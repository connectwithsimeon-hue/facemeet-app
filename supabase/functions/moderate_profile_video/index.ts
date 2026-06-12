import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

type ModerationStatus = "approved" | "rejected" | "needs_review";

const ADMIN_VIDEO_REVIEW_URL = "https://facemeet.app/admin";
const SUPPORT_EMAIL = Deno.env.get("SUPPORT_EMAIL") || "support@facemeet.app";

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizeFrameUrls(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item) => typeof item === "string")
    .map((item) => item.trim())
    .filter(Boolean)
    .slice(0, 5);
}

function hasOpenAiFlag(result: any): boolean {
  const item = result?.results?.[0];
  if (item?.flagged === true) return true;

  const categories = item?.categories ?? {};
  const flaggedCategory = Object.entries(categories).some(([, value]) => value === true);
  if (flaggedCategory) return true;

  const scores = item?.category_scores ?? {};
  return Object.values(scores).some((value) => typeof value === "number" && value >= 0.72);
}

function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, i + chunkSize);
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
}

async function fetchFrameAsDataUrl(url: string, index: number) {
  const response = await fetch(url);
  if (!response.ok) {
    return {
      ok: false,
      reason: `frame_${index}_http_${response.status}`,
    };
  }

  const contentType = response.headers.get("content-type") || "image/jpeg";
  const buffer = await response.arrayBuffer();
  const size = buffer.byteLength;
  console.log("profile video moderation frame fetched", {
    frameIndex: index,
    contentType,
    size,
  });

  if (size === 0) {
    return {
      ok: false,
      reason: `frame_${index}_empty`,
    };
  }

  if (!contentType.startsWith("image/")) {
    return {
      ok: false,
      reason: `frame_${index}_unsupported_${contentType}`,
    };
  }

  return {
    ok: true,
    contentType,
    size,
    dataUrl: `data:${contentType};base64,${arrayBufferToBase64(buffer)}`,
  };
}

function summarizeModeration(result: any) {
  const item = result?.results?.[0] ?? {};
  const categories = item?.categories ?? {};
  const scores = item?.category_scores ?? {};
  const activeCategories = Object.entries(categories)
    .filter(([, value]) => value === true)
    .map(([key]) => key);
  const highScores = Object.entries(scores)
    .filter(([, value]) => typeof value === "number" && value >= 0.35)
    .map(([key, value]) => `${key}:${Number(value).toFixed(3)}`);
  return {
    flagged: item?.flagged === true,
    activeCategories,
    highScores,
  };
}

function classifyModerationResult(result: any): {
  status: ModerationStatus;
  reason: string;
} {
  const item = result?.results?.[0] ?? {};
  const categories = item?.categories ?? {};
  const scores = item?.category_scores ?? {};
  const severeCategories = [
    "sexual/minors",
    "violence/graphic",
    "self-harm/intent",
    "self-harm/instructions",
    "hate/threatening",
    "harassment/threatening",
  ];

  const severeFlag = severeCategories.some((key) => categories?.[key] === true);
  const severeScore = severeCategories.some((key) =>
    typeof scores?.[key] === "number" && scores[key] >= 0.45
  );
  if (severeFlag || severeScore) {
    return {
      status: "rejected",
      reason: "Profile video appears to violate FaceMeet safety standards.",
    };
  }

  if (item?.flagged === true || hasOpenAiFlag(result)) {
    return {
      status: "needs_review",
      reason: "Automated moderation flagged this video for manual review.",
    };
  }

  return {
    status: "approved",
    reason: "Automated moderation approved.",
  };
}

function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[char] ?? char));
}

async function sendNeedsReviewEmail(params: {
  userId: string;
  userEmail?: string | null;
  videoUrl: string;
  reason: string;
}) {
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  if (!resendApiKey) {
    console.warn("profile video moderation email skipped: RESEND_API_KEY is not configured");
    return;
  }

  const fromEmail = Deno.env.get("RESEND_FROM_EMAIL") || "FaceMeet Moderation <support@facemeet.app>";
  const subject = "FaceMeet profile video needs review";
  const safeUserEmail = params.userEmail || "Unknown email";
  const text = [
    "A FaceMeet profile video needs manual review.",
    "",
    `User ID: ${params.userId}`,
    `User email: ${safeUserEmail}`,
    `Reason: ${params.reason}`,
    `Video: ${params.videoUrl}`,
    `Admin dashboard: ${ADMIN_VIDEO_REVIEW_URL}`,
  ].join("\n");
  const html = `
    <div style="font-family:Arial,sans-serif;line-height:1.5;color:#16120f;">
      <h2 style="margin:0 0 12px;color:#e8503a;">FaceMeet profile video needs review</h2>
      <p>A profile video was marked <strong>needs_review</strong> and is hidden from Discover until approved.</p>
      <ul>
        <li><strong>User ID:</strong> ${escapeHtml(params.userId)}</li>
        <li><strong>User email:</strong> ${escapeHtml(safeUserEmail)}</li>
        <li><strong>Reason:</strong> ${escapeHtml(params.reason)}</li>
      </ul>
      <p><a href="${escapeHtml(params.videoUrl)}">Open video</a></p>
      <p><a href="${ADMIN_VIDEO_REVIEW_URL}">Open FaceMeet Admin</a></p>
    </div>
  `;

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: fromEmail,
      to: SUPPORT_EMAIL,
      subject,
      text,
      html,
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error("profile video moderation email failed:", errorText);
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const openAiKey = Deno.env.get("OPENAI_API_KEY");

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const { data: authData, error: authError } = await userClient.auth.getUser();
    const userId = authData?.user?.id;
    const userEmail = authData?.user?.email;
    if (authError || !userId) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const body = await req.json().catch(() => ({}));
    const videoUrl = typeof body.video_url === "string" ? body.video_url.trim() : "";
    const frameUrls = normalizeFrameUrls(body.frame_urls);

    if (!videoUrl) {
      return jsonResponse({ error: "Missing video_url" }, 400);
    }

    console.log("profile video moderation started", {
      userId,
      hasVideoUrl: true,
      videoUrlReceived: true,
      frameCount: frameUrls.length,
      frameUrlHosts: frameUrls.map((url) => {
        try {
          return new URL(url).host;
        } catch (_) {
          return "invalid-url";
        }
      }),
    });

    await adminClient
      .from("users")
      .update({
        profile_video_url: videoUrl,
        moderation_status: "pending",
        moderation_reason: "Automated moderation started.",
        moderated_at: null,
      })
      .eq("id", userId);

    if (!openAiKey) {
      const reason = "Automated moderation is not configured.";
      console.warn("profile video moderation needs_review", {
        userId,
        reason,
      });
      await adminClient
        .from("users")
        .update({
          moderation_status: "needs_review",
          moderation_reason: reason,
          moderated_at: new Date().toISOString(),
        })
        .eq("id", userId);

      await sendNeedsReviewEmail({ userId, userEmail, videoUrl, reason });

      return jsonResponse({
        moderation_status: "needs_review",
        moderation_reason: reason,
      });
    }

    if (frameUrls.length === 0) {
      const reason = "Missing moderation frames";
      console.warn("profile video moderation needs_review", {
        userId,
        reason,
        videoUrlReceived: true,
      });
      await adminClient
        .from("users")
        .update({
          moderation_status: "needs_review",
          moderation_reason: reason,
          moderated_at: new Date().toISOString(),
        })
        .eq("id", userId);

      await sendNeedsReviewEmail({ userId, userEmail, videoUrl, reason });

      return jsonResponse({
        moderation_status: "needs_review",
        moderation_reason: reason,
      });
    }

    const fetchedFrames = [];
    for (let i = 0; i < frameUrls.length; i++) {
      const fetched = await fetchFrameAsDataUrl(frameUrls[i], i);
      if (!fetched.ok) {
        const reason = fetched.reason?.startsWith("frame_")
          ? "Unable to access frames"
          : "Unsupported video/frame format";
        console.warn("profile video moderation needs_review", {
          userId,
          reason,
          frameIndex: i,
          frameError: fetched.reason,
        });
        await adminClient
          .from("users")
          .update({
            moderation_status: "needs_review",
            moderation_reason: reason,
            moderated_at: new Date().toISOString(),
          })
          .eq("id", userId);

        await sendNeedsReviewEmail({ userId, userEmail, videoUrl, reason });

        return jsonResponse({
          moderation_status: "needs_review",
          moderation_reason: reason,
          frame_error: fetched.reason,
        });
      }
      fetchedFrames.push(fetched);
    }

    const framesToModerate = fetchedFrames.slice(0, 3);
    console.log("profile video moderation selected frames", {
      userId,
      frameCountReceived: fetchedFrames.length,
      frameCountSelected: framesToModerate.length,
    });

    let finalStatus: ModerationStatus = "approved";
    let finalReason = "Automated moderation approved.";
    const frameSummaries = [];

    for (let i = 0; i < framesToModerate.length; i++) {
      const frame = framesToModerate[i];
      const moderationInput = [{
        type: "image_url",
        image_url: { url: frame.dataUrl },
      }];

      console.log("profile video moderation calling OpenAI", {
        userId,
        frameIndex: i,
        frameCount: 1,
        frameType: frame.contentType,
        frameSize: frame.size,
        model: "omni-moderation-latest",
      });

      const moderationResponse = await fetch("https://api.openai.com/v1/moderations", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${openAiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: "omni-moderation-latest",
          input: moderationInput,
        }),
      });

      if (!moderationResponse.ok) {
        const errorText = await moderationResponse.text();
        console.error("profile video moderation API error:", {
          userId,
          frameIndex: i,
          error: errorText,
        });
        const debugError = errorText.slice(0, 500);
        const reason = errorText.includes("maximum") || errorText.includes("invalid_request")
          ? "OpenAI rejected moderation request"
          : "OpenAI moderation unavailable";

        await adminClient
          .from("users")
          .update({
            moderation_status: "needs_review",
            moderation_reason: reason,
            moderated_at: new Date().toISOString(),
          })
          .eq("id", userId);

        await sendNeedsReviewEmail({ userId, userEmail, videoUrl, reason });

        return jsonResponse({
          moderation_status: "needs_review",
          moderation_reason: reason,
          debug_error: debugError,
        });
      }

      const result = await moderationResponse.json();
      const summary = summarizeModeration(result);
      const decision = classifyModerationResult(result);
      frameSummaries.push({
        frameIndex: i,
        status: decision.status,
        reason: decision.reason,
        ...summary,
      });
      console.log("profile video moderation OpenAI success", {
        userId,
        frameIndex: i,
        ...summary,
        frameDecision: decision.status,
      });

      if (decision.status === "rejected") {
        finalStatus = "rejected";
        finalReason = decision.reason;
        break;
      }
      if (decision.status === "needs_review") {
        finalStatus = "needs_review";
        finalReason = decision.reason;
      }
    }

    console.log("profile video moderation frame decisions", {
      userId,
      frameSummaries,
      finalStatus,
      finalReason,
    });

    const status: ModerationStatus = finalStatus;
    const reason = finalReason;

    console.log("profile video moderation final decision", {
      userId,
      status,
      reason,
      frameCount: frameUrls.length,
      checkedFrameCount: framesToModerate.length,
    });

    if (status === "needs_review") {
      await sendNeedsReviewEmail({ userId, userEmail, videoUrl, reason });
    }

    const { error: updateError } = await adminClient
      .from("users")
      .update({
        profile_video_url: videoUrl,
        moderation_status: status,
        moderation_reason: reason,
        moderated_at: new Date().toISOString(),
      })
      .eq("id", userId);

    if (updateError) {
      console.error("profile video moderation update error:", updateError);
      return jsonResponse({ error: "Could not save moderation result" }, 500);
    }

    return jsonResponse({
      moderation_status: status,
      moderation_reason: reason,
    });
  } catch (err) {
    console.error("moderate_profile_video error:", err);
    return jsonResponse({
      moderation_status: "needs_review",
      moderation_reason: "Automated moderation failed unexpectedly.",
    });
  }
});
