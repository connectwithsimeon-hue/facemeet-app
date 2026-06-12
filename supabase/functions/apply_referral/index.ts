import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildRewardEmailHtml, sendTransactionalEmail } from "../_shared/email.ts";
import { sendWebPushToUser } from "../_shared/web_push.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function cleanReferralCode(value: unknown) {
  if (typeof value !== "string") return "";
  return value.trim().replace(/[^a-zA-Z0-9_-]/g, "").slice(0, 64);
}

function sanitizeErrorMessage(value: unknown) {
  if (!(value instanceof Error)) return "unknown_error";
  return value.message.slice(0, 240);
}

function buildInviteeDisplayName(user: { first_name?: unknown; username?: unknown } | null) {
  if (typeof user?.first_name === "string" && user.first_name.trim()) {
    return user.first_name.trim();
  }
  if (typeof user?.username === "string" && user.username.trim()) {
    return user.username.trim();
  }
  return "";
}

function buildReferralRewardMessage(inviteeDisplayName: string) {
  if (inviteeDisplayName) {
    return `${inviteeDisplayName} joined FaceMeet using your invite.`;
  }
  return "Someone joined FaceMeet using your invite.";
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authorization = req.headers.get("authorization") ?? "";
    const token = authorization.replace(/^Bearer\s+/i, "").trim();

    if (!token) {
      console.log("APPLY REFERRAL: authenticated no");
      return jsonResponse({ error: "missing_authorization" }, 401);
    }

    const { data: authData, error: authError } = await supabase.auth.getUser(
      token,
    );
    if (authError || !authData.user) {
      console.log("APPLY REFERRAL: authenticated no");
      return jsonResponse({ error: "invalid_authorization" }, 401);
    }

    console.log("APPLY REFERRAL: authenticated yes");

    const referredUserId = authData.user.id;
    const { data: referredUser, error: referredUserLookupError } = await supabase
      .from("users")
      .select("first_name, username")
      .eq("id", referredUserId)
      .maybeSingle();

    if (referredUserLookupError) {
      console.error("APPLY REFERRAL: referred user lookup failed");
    }

    const body = await req.json().catch(() => ({}));
    const referralCode = cleanReferralCode(body.referral_code);

    console.log(
      `APPLY REFERRAL: referral code present ${referralCode ? "yes" : "no"}`,
    );

    if (!referralCode) {
      return jsonResponse({ error: "missing_referral_code" }, 400);
    }

    const { data: existingAttribution, error: existingError } = await supabase
      .from("referral_attributions")
      .select("id, referrer_id, referral_code, reward_status")
      .eq("referred_user_id", referredUserId)
      .maybeSingle();

    if (existingError) {
      console.error("APPLY REFERRAL: existing attribution lookup failed");
      return jsonResponse({ error: "referral_lookup_failed" }, 500);
    }

    let attribution = existingAttribution;
    let canonicalCode = existingAttribution?.referral_code ?? "";
    let referrerId = existingAttribution?.referrer_id ?? "";

    if (!attribution) {
      const { data: referrer, error: referrerError } = await supabase
        .from("users")
        .select("id, referral_code, username")
        .or(`referral_code.eq.${referralCode},username.eq.${referralCode}`)
        .limit(1)
        .maybeSingle();

      if (referrerError) {
        console.error("APPLY REFERRAL: referrer lookup failed");
        return jsonResponse({ error: "referrer_lookup_failed" }, 500);
      }

      console.log(`APPLY REFERRAL: referrer found ${referrer ? "yes" : "no"}`);

      if (!referrer) {
        return jsonResponse({ error: "invalid_referral_code" }, 404);
      }

      if (referrer.id === referredUserId) {
        console.log("APPLY REFERRAL: self referral blocked yes");
        return jsonResponse({ success: true, self_referral: true });
      }

      canonicalCode =
        typeof referrer.referral_code === "string" && referrer.referral_code
          ? referrer.referral_code
          : referralCode;
      referrerId = referrer.id;

      const { data: insertedAttribution, error: insertError } = await supabase
        .from("referral_attributions")
        .insert({
          referrer_id: referrerId,
          referred_user_id: referredUserId,
          referral_code: canonicalCode,
          reward_status: "pending",
        })
        .select("id, referrer_id, referral_code, reward_status")
        .maybeSingle();

      if (insertError) {
        if (insertError.code !== "23505") {
          console.error("APPLY REFERRAL: attribution save failed");
          return jsonResponse({ error: "referral_save_failed" }, 500);
        }

        const { data: conflictedAttribution, error: conflictedLookupError } =
          await supabase
            .from("referral_attributions")
            .select("id, referrer_id, referral_code, reward_status")
            .eq("referred_user_id", referredUserId)
            .maybeSingle();

        if (conflictedLookupError || !conflictedAttribution) {
          console.error("APPLY REFERRAL: conflicted attribution lookup failed");
          return jsonResponse({ error: "referral_lookup_failed" }, 500);
        }

        attribution = conflictedAttribution;
        canonicalCode = conflictedAttribution.referral_code;
        referrerId = conflictedAttribution.referrer_id;
      } else {
        attribution = insertedAttribution;
      }
    } else {
      console.log("APPLY REFERRAL: existing attribution found yes");
    }

    if (!attribution) {
      return jsonResponse({ error: "referral_lookup_failed" }, 500);
    }

    if (attribution.reward_status === "credited") {
      console.log("APPLY REFERRAL: already credited yes");
      return jsonResponse({
        success: true,
        already_applied: true,
        reward_status: "credited",
      });
    }

    const { error: updateReferredError } = await supabase
      .from("users")
      .update({ referred_by: canonicalCode })
      .eq("id", referredUserId);

    if (updateReferredError) {
      console.error("APPLY REFERRAL: referred user update failed");
      await supabase
        .from("referral_attributions")
        .update({
          reward_status: "failed",
          error_message: "referred_user_update_failed",
        })
        .eq("id", attribution.id);
      return jsonResponse({ error: "referred_user_update_failed" }, 500);
    }

    const { data: claimedAttribution, error: claimError } = await supabase
      .from("referral_attributions")
      .update({
        reward_status: "processing",
        error_message: null,
      })
      .eq("id", attribution.id)
      .in("reward_status", ["pending", "failed"])
      .select("id, reward_status")
      .maybeSingle();

    if (claimError) {
      console.error("APPLY REFERRAL: reward claim failed");
      return jsonResponse({ error: "referral_claim_failed" }, 500);
    }

    if (!claimedAttribution) {
      const { data: refreshedAttribution, error: refreshedError } =
        await supabase
          .from("referral_attributions")
          .select("reward_status")
          .eq("id", attribution.id)
          .maybeSingle();

      if (refreshedError) {
        console.error("APPLY REFERRAL: reward refresh lookup failed");
        return jsonResponse({ error: "referral_lookup_failed" }, 500);
      }

      if (refreshedAttribution?.reward_status === "credited") {
        console.log("APPLY REFERRAL: already credited yes");
        return jsonResponse({
          success: true,
          already_applied: true,
          reward_status: "credited",
        });
      }

      console.log("APPLY REFERRAL: reward retry in progress yes");
      return jsonResponse(
        { error: "referral_reward_in_progress", retryable: true },
        409,
      );
    }

    const { error: rewardError } = await supabase.rpc(
      "award_referral_spark_on_join",
      { p_referred_user_id: referredUserId },
    );

    if (rewardError) {
      console.error("APPLY REFERRAL: reward failed");
      await supabase
        .from("referral_attributions")
        .update({
          reward_status: "failed",
          error_message: sanitizeErrorMessage(rewardError),
        })
        .eq("id", attribution.id);
      return jsonResponse({ error: "referral_reward_failed" }, 500);
    }

    const { error: creditUpdateError } = await supabase
      .from("referral_attributions")
      .update({
        reward_status: "credited",
        reward_credited_at: new Date().toISOString(),
        error_message: null,
      })
      .eq("id", attribution.id);

    if (creditUpdateError) {
      console.error("APPLY REFERRAL: reward status update failed");
      return jsonResponse({ error: "referral_status_update_failed" }, 500);
    }

    console.log("APPLY REFERRAL: saved yes");
    console.log("APPLY REFERRAL: reward credited yes");

    const inviteeDisplayName = buildInviteeDisplayName(referredUser);
    const referralRewardMessage = buildReferralRewardMessage(inviteeDisplayName);

    console.log(
      `REFERRAL EMAIL: reward credited yes/no=${creditUpdateError ? "no" : "yes"}`,
    );
    let referrerEmail = "";
    if (referrerId) {
      const { data: referrerAuthData, error: referrerAuthError } =
        await supabase.auth.admin.getUserById(referrerId);
      if (referrerAuthError) {
        console.error("APPLY REFERRAL: referrer auth lookup failed");
      } else if (typeof referrerAuthData.user?.email === "string") {
        referrerEmail = referrerAuthData.user.email.trim();
      }
    }
    console.log(
      `REFERRAL EMAIL: referrer email present yes/no=${referrerEmail ? "yes" : "no"}`,
    );
    console.log(
      `REFERRAL EMAIL: invitee display name present yes/no=${inviteeDisplayName ? "yes" : "no"}`,
    );
    if (referrerEmail) {
      console.log("REFERRAL EMAIL: send attempted yes/no=yes");
      const emailResult = await sendTransactionalEmail({
        from: "FaceMeet Rewards <support@facemeet.app>",
        to: referrerEmail,
        subject: "You just earned 1 Spark ⚡",
        text: [
          referralRewardMessage,
          "",
          "We just added 1 Spark to your account.",
          "",
          "Keep sharing your invite link — every new friend who joins helps you earn more Sparks.",
        ].join("\n"),
        html: buildRewardEmailHtml({
          eyebrow: "FaceMeet Rewards",
          title: "You just earned 1 Spark ⚡",
          paragraphs: [
            referralRewardMessage,
            "We just added 1 Spark to your account.",
            "Keep sharing your invite link — every new friend who joins helps you earn more Sparks.",
          ],
          ctaLabel: "Open FaceMeet",
          ctaUrl: "https://app.facemeet.app",
          footer: "FaceMeet — See them before you swipe.",
        }),
      });
      console.log(
        `REFERRAL EMAIL: send success/failure=${emailResult.success ? "success" : "failure"}`,
      );
    } else {
      console.log("REFERRAL EMAIL: send attempted yes/no=no");
    }

    console.log(
      `REFERRAL PUSH: reward credited yes/no=${creditUpdateError ? "no" : "yes"}`,
    );
    console.log(
      `REFERRAL PUSH: referrer present yes/no=${referrerId ? "yes" : "no"}`,
    );
    console.log(
      `REFERRAL PUSH: invitee display name present yes/no=${inviteeDisplayName ? "yes" : "no"}`,
    );

    if (referrerId) {
      console.log("REFERRAL PUSH: send attempted yes/no=yes");
      const pushResult = await sendWebPushToUser({
        adminClient: supabase,
        userId: referrerId,
        type: "referral_reward",
        title: "You earned 1 Spark ⚡",
        body: referralRewardMessage,
        data: {
          type: "referral_reward",
          url: "/",
          referred_user_id: referredUserId,
        },
      });
      console.log(
        `REFERRAL PUSH: send success/failure=${pushResult.success_count > 0 ? "success" : "failure"}`,
      );
    } else {
      console.log("REFERRAL PUSH: send attempted yes/no=no");
    }

    return jsonResponse({ success: true, reward_status: "credited" });
  } catch (err) {
    console.error(
      `APPLY REFERRAL: unexpected error=${err instanceof Error ? err.name : "unknown_error"}`,
    );
    return jsonResponse({ error: "unexpected_referral_error" }, 500);
  }
});
