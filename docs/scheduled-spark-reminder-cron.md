# Scheduled Spark Reminder Cron

## Worker

- Supabase Edge Function: `scheduled_spark_reminder_worker`
- Target URL format:
  `https://<project-ref>.supabase.co/functions/v1/scheduled_spark_reminder_worker`
- Current FaceMeet project ref: `vbaiivsvjdntzaffboue`
- FaceMeet target URL:
  `https://vbaiivsvjdntzaffboue.supabase.co/functions/v1/scheduled_spark_reminder_worker`

## Cadence

Invoke the worker every 5 minutes.

Recommended cron expression:

```cron
*/5 * * * *
```

## Auth

Invoke the function with the Supabase service-role key in the request
authorization header:

```http
Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>
Content-Type: application/json
```

Request body:

```json
{}
```

Do not put the service-role key in Flutter, Android, PWA, JavaScript client
source, service workers, public websites, or committed docs.

## Supabase Dashboard Setup

If the CLI does not expose scheduled Edge Function configuration:

1. Open the Supabase dashboard for the FaceMeet project.
2. Go to Edge Functions.
3. Select or create a scheduled invocation for
   `scheduled_spark_reminder_worker`.
4. Set the cadence to every 5 minutes.
5. Use `POST`.
6. Add the service-role bearer authorization header securely in the dashboard
   secret/header configuration.
7. Save and enable the schedule.

## What The Worker Sends

The worker checks accepted rows in `public.spark_session_schedules`.

- `spark_schedule_reminder`: sent about 10 minutes before `accepted_time`.
- `spark_schedule_ready`: sent at the scheduled time, within the join-ready
  grace window.

The worker sends to both scheduled Spark participants through the existing
`send_push_notification` function, so Android native push and PWA web push use
the existing delivery stack.

## Android Verification Checklist

- Android receives `spark_schedule_accepted`.
- Android receives `spark_schedule_reminder`.
- Android receives `spark_schedule_ready`.
- Tapping any scheduled Spark notification opens the Sessions/Sparks area.
- Dating/friendship copy stays generic: `Your 3-minute intro...`.
- Professional copy uses `Professional Connection`.
- No service-role key is present in Android code.
- No Daily API key is present in Android code.
- Existing instant Start Now Spark flow still works.
- Existing secure Daily room/token flow still works.

## PWA Verification Checklist

- PWA receives `spark_schedule_accepted`.
- PWA receives `spark_schedule_reminder`.
- PWA receives `spark_schedule_ready`.
- Tapping scheduled Spark web push opens the PWA and routes to the scheduled
  intro area.
- `web/facemeet_web_push_sw.js` keeps handling
  `spark_schedule_reminder` and `spark_schedule_ready`.
