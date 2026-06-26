import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

const REMINDER_MINUTES = 10;
const JOIN_READY_GRACE_MINUTES = 15;
const MAX_CANDIDATES = 50;

type SupabaseClient = ReturnType<typeof createClient>;

type ScheduleRow = {
  id: string;
  match_id: string;
  proposer_user_id: string;
  recipient_user_id: string;
  spark_type: string | null;
  accepted_time: string;
};

type PushResult = {
  user_id_short: string;
  sent: number;
  reason: string;
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function shortId(value: unknown) {
  return typeof value === "string" && value.length >= 8
    ? value.slice(0, 8)
    : "none";
}

function minutesFromNow(minutes: number) {
  return new Date(Date.now() + minutes * 60 * 1000).toISOString();
}

function minutesAgo(minutes: number) {
  return new Date(Date.now() - minutes * 60 * 1000).toISOString();
}

function normalizedSparkType(value: string | null | undefined) {
  return value === "professional" ? "professional" : "social";
}

function copyFor(kind: "reminder" | "ready", sparkType: string | null) {
  const professional = normalizedSparkType(sparkType) === "professional";

  if (kind === "reminder") {
    return professional
      ? {
        title: "Professional Connection intro soon",
        body: "Your Professional Connection intro is coming up soon.",
      }
      : {
        title: "FaceMeet intro soon",
        body: "Your 3-minute intro is coming up soon.",
      };
  }

  return professional
    ? {
      title: "Professional Connection intro ready",
      body: "Your Professional Connection intro is ready.",
    }
    : {
      title: "FaceMeet intro ready",
      body: "Your 3-minute intro is ready.",
    };
}

function uniqueParticipants(schedule: ScheduleRow) {
  return Array.from(
    new Set([schedule.proposer_user_id, schedule.recipient_user_id]),
  );
}

async function authorized(req: Request) {
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
  const authorization = req.headers.get("Authorization")?.trim();

  if (serviceRoleKey && authorization === `Bearer ${serviceRoleKey}`) {
    return true;
  }

  const cronSecret = Deno.env.get("SCHEDULED_SPARK_REMINDER_SECRET")?.trim();
  if (cronSecret && req.headers.get("x-cron-secret")?.trim() === cronSecret) {
    return true;
  }

  return false;
}

async function sendPush(
  schedule: ScheduleRow,
  userId: string,
  type: "spark_schedule_reminder" | "spark_schedule_ready",
  copy: { title: string; body: string },
): Promise<PushResult> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const response = await fetch(`${supabaseUrl}/functions/v1/send_push_notification`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${serviceRoleKey}`,
      apikey: serviceRoleKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      target_user_id: userId,
      user_id: userId,
      type,
      title: copy.title,
      body: copy.body,
      data: {
        type,
        schedule_id: schedule.id,
        match_id: schedule.match_id,
        spark_type: schedule.spark_type ?? "dating",
        accepted_time: schedule.accepted_time,
      },
    }),
  });

  const payload = await response.json().catch(() => ({}));
  return {
    user_id_short: shortId(userId),
    sent: Number(payload?.sent ?? 0),
    reason: response.ok ? String(payload?.reason ?? "unknown") : "send_failed",
  };
}

async function claimReminder(
  supabase: SupabaseClient,
  scheduleId: string,
  nowIso: string,
) {
  const { data, error } = await supabase
    .from("spark_session_schedules")
    .update({ reminder_sent_at: nowIso })
    .eq("id", scheduleId)
    .eq("status", "accepted")
    .is("reminder_sent_at", null)
    .select("id, match_id, proposer_user_id, recipient_user_id, spark_type, accepted_time")
    .maybeSingle();

  if (error) throw error;
  return data as ScheduleRow | null;
}

async function claimJoinReady(
  supabase: SupabaseClient,
  scheduleId: string,
  nowIso: string,
) {
  const { data, error } = await supabase
    .from("spark_session_schedules")
    .update({ join_ready_sent_at: nowIso })
    .eq("id", scheduleId)
    .eq("status", "accepted")
    .is("join_ready_sent_at", null)
    .select("id, match_id, proposer_user_id, recipient_user_id, spark_type, accepted_time")
    .maybeSingle();

  if (error) throw error;
  return data as ScheduleRow | null;
}

async function processReminderCandidates(
  supabase: SupabaseClient,
  dryRun: boolean,
) {
  const nowIso = new Date().toISOString();
  const reminderUntil = minutesFromNow(REMINDER_MINUTES);

  const { data, error } = await supabase
    .from("spark_session_schedules")
    .select("id, match_id, proposer_user_id, recipient_user_id, spark_type, accepted_time")
    .eq("status", "accepted")
    .not("accepted_time", "is", null)
    .is("reminder_sent_at", null)
    .gt("accepted_time", nowIso)
    .lte("accepted_time", reminderUntil)
    .order("accepted_time", { ascending: true })
    .limit(MAX_CANDIDATES);

  if (error) throw error;

  const results = [];
  for (const candidate of (data ?? []) as ScheduleRow[]) {
    const claimed = dryRun
      ? candidate
      : await claimReminder(supabase, candidate.id, nowIso);
    if (!claimed) continue;

    const message = copyFor("reminder", claimed.spark_type);
    const pushes = dryRun
      ? uniqueParticipants(claimed).map((userId) => ({
        user_id_short: shortId(userId),
        sent: 0,
        reason: "dry_run",
      }))
      : await Promise.all(
        uniqueParticipants(claimed).map((userId) =>
          sendPush(claimed, userId, "spark_schedule_reminder", message)
        ),
      );

    results.push({
      schedule_id_short: shortId(claimed.id),
      match_id_short: shortId(claimed.match_id),
      accepted_time: claimed.accepted_time,
      push_results: pushes,
    });
  }

  return {
    candidate_count: data?.length ?? 0,
    claimed_count: results.length,
    results,
  };
}

async function processJoinReadyCandidates(
  supabase: SupabaseClient,
  dryRun: boolean,
) {
  const nowIso = new Date().toISOString();
  const joinReadySince = minutesAgo(JOIN_READY_GRACE_MINUTES);

  const { data, error } = await supabase
    .from("spark_session_schedules")
    .select("id, match_id, proposer_user_id, recipient_user_id, spark_type, accepted_time")
    .eq("status", "accepted")
    .not("accepted_time", "is", null)
    .is("join_ready_sent_at", null)
    .lte("accepted_time", nowIso)
    .gte("accepted_time", joinReadySince)
    .order("accepted_time", { ascending: true })
    .limit(MAX_CANDIDATES);

  if (error) throw error;

  const results = [];
  for (const candidate of (data ?? []) as ScheduleRow[]) {
    const claimed = dryRun
      ? candidate
      : await claimJoinReady(supabase, candidate.id, nowIso);
    if (!claimed) continue;

    const message = copyFor("ready", claimed.spark_type);
    const pushes = dryRun
      ? uniqueParticipants(claimed).map((userId) => ({
        user_id_short: shortId(userId),
        sent: 0,
        reason: "dry_run",
      }))
      : await Promise.all(
        uniqueParticipants(claimed).map((userId) =>
          sendPush(claimed, userId, "spark_schedule_ready", message)
        ),
      );

    results.push({
      schedule_id_short: shortId(claimed.id),
      match_id_short: shortId(claimed.match_id),
      accepted_time: claimed.accepted_time,
      push_results: pushes,
    });
  }

  return {
    candidate_count: data?.length ?? 0,
    claimed_count: results.length,
    results,
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  if (!(await authorized(req))) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  try {
    const body = await req.json().catch(() => ({}));
    const dryRun = body?.dry_run === true ||
      new URL(req.url).searchParams.get("dry_run") === "1";

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const reminder = await processReminderCandidates(supabase, dryRun);
    const joinReady = await processJoinReadyCandidates(supabase, dryRun);

    return jsonResponse({
      success: true,
      dry_run: dryRun,
      reminder,
      join_ready: joinReady,
    });
  } catch (error) {
    console.error(
      "Scheduled Spark reminder worker error:",
      error instanceof Error ? error.message : "unknown",
    );
    return jsonResponse(
      {
        success: false,
        error: error instanceof Error ? error.message : "worker_failed",
      },
      500,
    );
  }
});
