import webpush from "npm:web-push@3.6.7";

function cleanPayload(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Record<string, unknown>;
}

export interface WebPushSendParams {
  adminClient: any;
  userId: string;
  type: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
}

export async function sendWebPushToUser(params: WebPushSendParams) {
  const vapidSubject = Deno.env.get("VAPID_SUBJECT") ||
    "mailto:support@facemeet.app";
  const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY");
  const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY");

  if (!vapidPublicKey || !vapidPrivateKey) {
    console.error("WEB PUSH SEND: missing VAPID keys");
    return {
      success: false,
      error: "missing_vapid_keys",
      subscriptions_found: 0,
      success_count: 0,
      failure_count: 0,
      inactive_count: 0,
    };
  }

  const payloadData = cleanPayload(params.data);
  const { data: subscriptions, error: subError } = await params.adminClient
    .from("web_push_subscriptions")
    .select("id, endpoint, p256dh, auth")
    .eq("user_id", params.userId)
    .eq("is_active", true);

  if (subError) {
    console.error("WEB PUSH SEND: subscription lookup failed", {
      message: subError.message,
    });
    return {
      success: false,
      error: "subscription_lookup_failed",
      subscriptions_found: 0,
      success_count: 0,
      failure_count: 0,
      inactive_count: 0,
    };
  }

  console.log("WEB PUSH SEND: subscriptions found", {
    recipientUser: params.userId,
    count: subscriptions?.length ?? 0,
  });

  webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);

  let successCount = 0;
  let failureCount = 0;
  let inactiveCount = 0;
  const payload = JSON.stringify({
    title: params.title,
    body: params.body,
    data: {
      ...payloadData,
      type: params.type,
    },
  });

  for (const subscription of subscriptions ?? []) {
    try {
      await webpush.sendNotification(
        {
          endpoint: subscription.endpoint,
          keys: {
            p256dh: subscription.p256dh,
            auth: subscription.auth,
          },
        },
        payload,
      );
      successCount += 1;
    } catch (error) {
      failureCount += 1;
      const statusCode = (error as { statusCode?: number })?.statusCode;
      console.error("WEB PUSH SEND: subscription send failed", {
        subscriptionId: subscription.id,
        statusCode,
        message: error instanceof Error ? error.message : "Unknown error",
      });
      if (statusCode === 404 || statusCode === 410) {
        await params.adminClient
          .from("web_push_subscriptions")
          .update({
            is_active: false,
            updated_at: new Date().toISOString(),
          })
          .eq("id", subscription.id);
        inactiveCount += 1;
      }
    }
  }

  console.log("WEB PUSH SEND: completed", {
    type: params.type,
    recipientUser: params.userId,
    successCount,
    failureCount,
    inactiveCount,
  });

  return {
    success: true,
    subscriptions_found: subscriptions?.length ?? 0,
    success_count: successCount,
    failure_count: failureCount,
    inactive_count: inactiveCount,
  };
}
