import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendWebPushToUser } from "../_shared/web_push.ts";

const jsonHeaders = { "Content-Type": "application/json" };

type DeviceTokenRow = {
  fcm_token: string;
  platform: string | null;
};

serve(async (req) => {
  try {
    const { user_id, type, title, body, data } = await req.json();

    if (!user_id || typeof user_id !== "string") {
      return new Response(JSON.stringify({ error: "Missing user_id" }), {
        status: 400,
        headers: jsonHeaders,
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: tokens, error } = await supabase
      .from("device_tokens")
      .select("fcm_token, platform")
      .eq("user_id", user_id)
      .eq("notifications_enabled", true);

    if (error) {
      console.error("Native push token lookup failed:", error.message);
      return new Response(
        JSON.stringify({
          sent: 0,
          reason: "native_token_lookup_failed",
          native_tokens_found: 0,
          android_tokens_found: 0,
          native_sent: 0,
          web_subscriptions_found: 0,
          web_sent: 0,
        }),
        { status: 500, headers: jsonHeaders },
      );
    }

    const nativeTokens = (tokens ?? []) as DeviceTokenRow[];
    const nativeTokensFound = nativeTokens.length;
    const androidTokensFound = nativeTokens.filter((row) =>
      row.platform === "android"
    ).length;

    console.log("Native push tokens found:", {
      count: nativeTokensFound,
      androidCount: androidTokensFound,
    });

    const stringData: Record<string, string> = {
      type: String(type || ""),
      ...Object.fromEntries(
        Object.entries(data || {}).map(([key, value]) => [
          key,
          String(value ?? ""),
        ]),
      ),
    };

    let nativeSent = 0;
    let nativeFailureCount = 0;
    let nativeUnregisteredCount = 0;
    let nativeReason = nativeTokensFound > 0
      ? "native_attempted"
      : "no_native_tokens";

    const hasNativeConfig =
      !!Deno.env.get("FIREBASE_SERVICE_ACCOUNT")?.trim() &&
      !!Deno.env.get("FIREBASE_PROJECT_ID")?.trim();

    if (nativeTokensFound > 0 && !hasNativeConfig) {
      nativeReason = "native_push_not_configured";
    }

    if (nativeTokensFound > 0 && hasNativeConfig) {
      const serviceAccount = JSON.parse(Deno.env.get("FIREBASE_SERVICE_ACCOUNT")!);
      const projectId = Deno.env.get("FIREBASE_PROJECT_ID")!;
      const accessToken = await getFirebaseToken(serviceAccount);
      console.log("Native push access token acquired:", accessToken ? "yes" : "no");

      for (const { fcm_token } of nativeTokens) {
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
                    title: title || "FaceMeet",
                    body: body || "",
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
            nativeSent += 1;
          } else {
            nativeFailureCount += 1;
            const errorCode = fcmData.error?.details?.[0]?.errorCode ||
              fcmData.error?.status ||
              "unknown";
            console.log("Native push send failed:", { errorCode });
            if (errorCode === "UNREGISTERED") {
              nativeUnregisteredCount += 1;
            }
          }
        } catch (error) {
          nativeFailureCount += 1;
          console.error(
            "Native push send error:",
            error instanceof Error ? error.message : "unknown",
          );
        }
      }

      nativeReason = nativeSent > 0 ? "native_sent" : "native_send_failed";
    }

    const webResult = await sendWebPushToUser({
      adminClient: supabase,
      userId: user_id,
      type,
      title: title || "FaceMeet",
      body: body || "",
      data: data || {},
    });

    const webSubscriptionsFound = webResult.subscriptions_found ?? 0;
    const webSent = webResult.success_count ?? 0;
    const sent = nativeSent + webSent;
    const reason = sent > 0
      ? "sent"
      : nativeTokensFound === 0 && webSubscriptionsFound === 0
      ? "no_push_tokens"
      : nativeReason === "native_push_not_configured"
      ? "native_push_not_configured"
      : webResult.error ?? nativeReason;

    await supabase.from("notification_events").insert({
      user_id,
      type,
      title,
      body,
      payload: data || {},
      status: sent > 0 ? "sent" : "failed",
    });

    return new Response(
      JSON.stringify({
        sent,
        reason,
        native_tokens_found: nativeTokensFound,
        android_tokens_found: androidTokensFound,
        native_sent: nativeSent,
        native_failure_count: nativeFailureCount,
        native_unregistered_count: nativeUnregisteredCount,
        web_subscriptions_found: webSubscriptionsFound,
        web_sent: webSent,
        web_failure_count: webResult.failure_count ?? 0,
      }),
      { headers: jsonHeaders },
    );
  } catch (error) {
    console.error(
      "Function error:",
      error instanceof Error ? error.message : "unknown",
    );
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : "Unexpected push error",
      }),
      { status: 500, headers: jsonHeaders },
    );
  }
});

async function getFirebaseToken(serviceAccount: any): Promise<string> {
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

  const binaryKey = Uint8Array.from(atob(pemContent), (c) => c.charCodeAt(0));

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
  console.log("Token response received:", {
    accessTokenPresent: !!tokenData.access_token,
  });

  if (!tokenData.access_token) {
    throw new Error("Failed to get access token");
  }

  return tokenData.access_token as string;
}
