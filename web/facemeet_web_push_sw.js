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
    icon: "/icons/Icon-192.png",
    badge: "/icons/Icon-192.png",
    data: payload.data || {},
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
  const targetUrl = data.url || "/";
  const url = new URL(targetUrl, self.location.origin).href;

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if ("focus" in client) {
          client.postMessage({ type: "FACEMEET_WEB_PUSH_CLICK", data });
          return client.focus();
        }
      }
      return self.clients.openWindow(url);
    }),
  );
});
