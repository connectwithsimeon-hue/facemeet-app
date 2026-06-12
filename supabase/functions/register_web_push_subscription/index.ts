import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authorization = req.headers.get("authorization") ?? "";
    const token = authorization.replace(/^Bearer\s+/i, "").trim();

    if (!token) {
      console.log("REGISTER WEB PUSH: authenticated no");
      return new Response(
        JSON.stringify({ error: "missing_authorization" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { data: authData, error: authError } = await supabase.auth.getUser(token);
    if (authError || !authData.user) {
      console.log("REGISTER WEB PUSH: authenticated no");
      return new Response(
        JSON.stringify({ error: "invalid_authorization" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    console.log("REGISTER WEB PUSH: authenticated yes");

    const userId = authData.user.id;
    const body = await req.json();
    const endpoint = typeof body.endpoint === "string" ? body.endpoint.trim() : "";
    const p256dh = typeof body.p256dh === "string" ? body.p256dh.trim() : "";
    const auth = typeof body.auth === "string" ? body.auth.trim() : "";
    const userAgent = typeof body.user_agent === "string" ? body.user_agent : null;
    const platform = typeof body.platform === "string" ? body.platform : "web";

    console.log(`REGISTER WEB PUSH: endpoint present ${endpoint ? "yes" : "no"}`);

    if (!endpoint || !p256dh || !auth) {
      console.log("REGISTER WEB PUSH: saved no");
      return new Response(
        JSON.stringify({ error: "missing_subscription_fields" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { data: existing, error: existingError } = await supabase
      .from("web_push_subscriptions")
      .select("user_id")
      .eq("endpoint", endpoint)
      .maybeSingle();

    if (existingError) {
      console.error("REGISTER WEB PUSH: saved no; lookup failed");
      return new Response(
        JSON.stringify({ error: "subscription_lookup_failed" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const reassigned = !!existing?.user_id && existing.user_id !== userId;
    console.log(`REGISTER WEB PUSH: reassigned existing endpoint ${reassigned ? "yes" : "no"}`);

    const now = new Date().toISOString();
    const { error: upsertError } = await supabase
      .from("web_push_subscriptions")
      .upsert({
        user_id: userId,
        endpoint,
        p256dh,
        auth,
        user_agent: userAgent,
        platform,
        is_active: true,
        last_seen_at: now,
        updated_at: now,
      }, { onConflict: "endpoint" });

    if (upsertError) {
      console.error("REGISTER WEB PUSH: saved no; upsert failed");
      return new Response(
        JSON.stringify({ error: "subscription_save_failed" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    console.log("REGISTER WEB PUSH: saved yes");
    return new Response(
      JSON.stringify({ success: true, reassigned }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error(
      `REGISTER WEB PUSH: saved no; error=${err instanceof Error ? err.name : "unknown_error"}`,
    );
    return new Response(
      JSON.stringify({ error: "unexpected_registration_error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
