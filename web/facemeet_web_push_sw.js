self.addEventListener("push", (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (_) {
    payload = { title: "FaceMeet", body: event.data ? event.data.text() : "" };
  }

  const title = payload.title || "FaceMeet";
  const options = {
    body: payload.body || "",
    icon: payload.icon || "/icons/Icon-maskable-192.png",
    badge: payload.badge || "/icons/notification-badge.png",
    image: payload.image || "/icons/Icon-512.png",
    data: payload.data || {},
    vibrate: [80, 40, 80],
    tag: payload.tag || payload.data?.type || "facemeet",
  };

  console.info("WEB PUSH: push received", {
    type: options.data?.type || "unknown",
  });

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  console.info("WEB PUSH: notification clicked", {
    type: event.notification?.data?.type || "unknown",
  });
  event.notification.close();

  const data = event.notification.data || {};
  const professionalSparkSender =
    data.type === "new_spark" && data.spark_type === "professional"
      ? data.sender_user_id || data.professional_spark_sender_id || data.from_user_id
      : null;
  const sparkScheduleType =
    data.type === "spark_schedule_proposed" ||
    data.type === "spark_schedule_accepted" ||
    data.type === "spark_schedule_reminder" ||
    data.type === "spark_schedule_ready"
      ? data.type
      : null;
  const liveTopicSlug =
    data.type === "live_topic_invite" ? data.live_topic_slug || "" : "";
  const targetUrl =
    data.match_id && (data.type === "spark_session" || data.type === "new_match")
      ? `/?push_type=${encodeURIComponent(data.type)}&spark_match_id=${encodeURIComponent(data.match_id)}`
      : professionalSparkSender
      ? `/?push_type=new_spark&spark_type=professional&sender_user_id=${encodeURIComponent(professionalSparkSender)}`
      : sparkScheduleType
      ? `/?push_type=${encodeURIComponent(sparkScheduleType)}`
      : liveTopicSlug
      ? `/?push_type=live_topic_invite&live_topic_slug=${encodeURIComponent(liveTopicSlug)}`
      : data.url || "/";
  const url = new URL(targetUrl, self.location.origin).href;

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if ("focus" in client) {
          client.postMessage({ type: "FACEMEET_WEB_PUSH_CLICK", data });
          if ("navigate" in client) {
            return client.navigate(url).then((navigatedClient) => {
              return navigatedClient ? navigatedClient.focus() : client.focus();
            });
          }
          return client.focus();
        }
      }
      return self.clients.openWindow(url);
    }),
  );
});
