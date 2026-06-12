import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendWebPushToUser } from "../_shared/web_push.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData?.user) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const body = await req.json().catch(() => ({}));
    const recipientUserId = typeof body.user_id === "string" ? body.user_id : "";
    const type = typeof body.type === "string" ? body.type : "facemeet";
    const title = typeof body.title === "string" ? body.title : "FaceMeet";
    const notificationBody = typeof body.body === "string" ? body.body : "";
    const data = body.data;

    if (!recipientUserId) {
      return jsonResponse({ error: "Missing user_id" }, 400);
    }

    console.log("WEB PUSH SEND: event type", {
      type,
      recipientUser: recipientUserId,
    });

    const result = await sendWebPushToUser({
      adminClient,
      userId: recipientUserId,
      type,
      title,
      body: notificationBody,
      data,
    });

    if (!result.success && result.error === "missing_vapid_keys") {
      return jsonResponse({ error: "Web push is not configured" }, 500);
    }

    if (!result.success && result.error === "subscription_lookup_failed") {
      return jsonResponse({ error: "Could not load subscriptions" }, 500);
    }

    return jsonResponse({
      success: true,
      subscriptions_found: result.subscriptions_found,
      success_count: result.success_count,
      failure_count: result.failure_count,
      inactive_count: result.inactive_count,
    });
  } catch (error) {
    console.error("WEB PUSH SEND: unexpected error", {
      message: error instanceof Error ? error.message : "Unknown error",
    });
    return jsonResponse({ error: "Unexpected web push error" }, 500);
  }
});
