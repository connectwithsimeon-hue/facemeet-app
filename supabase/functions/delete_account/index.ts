import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2";

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

function safeErrorMessage(error: unknown) {
  if (!error) return "unknown error";
  if (typeof error === "object" && "message" in error) {
    return String((error as { message?: unknown }).message ?? "unknown error");
  }
  return String(error);
}

async function safeDelete(
  label: string,
  operation: PromiseLike<{ error: unknown }>,
) {
  const { error } = await operation;
  if (error) {
    console.warn(
      `delete_account: ${label} cleanup warning: ${safeErrorMessage(error)}`,
    );
  }
}

async function safeUpdate(
  label: string,
  operation: PromiseLike<{ error: unknown }>,
) {
  const { error } = await operation;
  if (error) {
    console.warn(
      `delete_account: ${label} update warning: ${safeErrorMessage(error)}`,
    );
  }
}

async function collectStoragePaths(
  adminClient: SupabaseClient,
  bucket: string,
  prefix: string,
): Promise<string[]> {
  const paths: string[] = [];
  const { data, error } = await adminClient.storage.from(bucket).list(prefix, {
    limit: 1000,
    sortBy: { column: "name", order: "asc" },
  });

  if (error) {
    console.warn(
      `delete_account: storage list warning bucket=${bucket}: ${
        safeErrorMessage(error)
      }`,
    );
    return paths;
  }

  for (const item of data ?? []) {
    const itemPath = prefix ? `${prefix}/${item.name}` : item.name;
    const metadata = (item as { metadata?: unknown }).metadata;
    const id = (item as { id?: unknown }).id;
    const isFolder = metadata == null && id == null;

    if (isFolder) {
      const nestedPaths = await collectStoragePaths(
        adminClient,
        bucket,
        itemPath,
      );
      paths.push(...nestedPaths);
    } else {
      paths.push(itemPath);
    }
  }

  return paths;
}

async function removeStoragePrefix(
  adminClient: SupabaseClient,
  bucket: string,
  prefix: string,
) {
  const paths = await collectStoragePaths(adminClient, bucket, prefix);
  if (paths.length === 0) return;

  const { error } = await adminClient.storage.from(bucket).remove(paths);
  if (error) {
    console.warn(
      `delete_account: storage remove warning bucket=${bucket}: ${
        safeErrorMessage(error)
      }`,
    );
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    const { data: authData, error: authError } = await userClient.auth
      .getUser();
    const userId = authData?.user?.id;

    if (authError || !userId) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const body = await req.json().catch(() => ({}));
    if (body?.confirmation !== "DELETE") {
      return jsonResponse(
        { error: "Type DELETE to confirm account deletion." },
        400,
      );
    }

    console.info(`delete_account: deletion started for user_id=${userId}`);

    await safeUpdate(
      "users local account references",
      adminClient
        .from("users")
        .update({
          stripe_customer_id: null,
          subscription_tier: "free",
          subscription_expires_at: null,
          is_online: false,
          last_seen_at: new Date().toISOString(),
        })
        .eq("id", userId),
    );

    await Promise.all([
      removeStoragePrefix(adminClient, "profile-videos", userId),
      removeStoragePrefix(
        adminClient,
        "profile-videos",
        `profile_videos/${userId}`,
      ),
      removeStoragePrefix(adminClient, "profile-thumbnails", userId),
    ]);

    await safeDelete(
      "device_tokens",
      adminClient.from("device_tokens").delete().eq("user_id", userId),
    );
    await safeDelete(
      "messages sent by user",
      adminClient.from("messages").delete().eq("sender_id", userId),
    );
    await safeDelete(
      "matches",
      adminClient
        .from("matches")
        .delete()
        .or(`user_1_id.eq.${userId},user_2_id.eq.${userId}`),
    );
    await safeDelete(
      "interactions",
      adminClient
        .from("interactions")
        .delete()
        .or(`from_user_id.eq.${userId},to_user_id.eq.${userId}`),
    );
    await safeDelete(
      "blocked_users",
      adminClient
        .from("blocked_users")
        .delete()
        .or(`blocker_user_id.eq.${userId},blocked_user_id.eq.${userId}`),
    );
    await safeDelete(
      "user_reports",
      adminClient
        .from("user_reports")
        .delete()
        .or(`reporter_user_id.eq.${userId},reported_user_id.eq.${userId}`),
    );
    await safeDelete(
      "moderation_events",
      adminClient
        .from("moderation_events")
        .delete()
        .or(`actor_user_id.eq.${userId},target_user_id.eq.${userId}`),
    );
    await safeDelete(
      "payments",
      adminClient.from("payments").delete().eq("user_id", userId),
    );

    const { error: deleteUserError } = await adminClient.auth.admin.deleteUser(
      userId,
    );
    if (deleteUserError) {
      console.error(
        `delete_account: auth user deletion failed for user_id=${userId}: ${safeErrorMessage(deleteUserError)}`,
      );
      return jsonResponse(
        { error: "Could not delete account. Please try again." },
        500,
      );
    }

    console.info(`delete_account: deletion completed for user_id=${userId}`);
    return jsonResponse({ success: true });
  } catch (err) {
    console.error(`delete_account: unexpected error: ${safeErrorMessage(err)}`);
    return jsonResponse(
      { error: "Account deletion failed. Please try again." },
      500,
    );
  }
});
