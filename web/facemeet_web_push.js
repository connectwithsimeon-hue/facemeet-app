(function () {
  function base64UrlToUint8Array(base64UrlString) {
    var padding = "=".repeat((4 - (base64UrlString.length % 4)) % 4);
    var base64 = (base64UrlString + padding).replace(/-/g, "+").replace(/_/g, "/");
    var rawData = window.atob(base64);
    var outputArray = new Uint8Array(rawData.length);
    for (var i = 0; i < rawData.length; ++i) {
      outputArray[i] = rawData.charCodeAt(i);
    }
    return outputArray;
  }

  function getPlatform() {
    var ua = window.navigator.userAgent || "";
    if (/iphone|ipad|ipod/i.test(ua)) return "ios_pwa";
    if (/android/i.test(ua)) return "android_pwa";
    return "web";
  }

  async function waitForPushServiceWorker(registration) {
    if (!registration) {
      throw new Error("missing_service_worker_registration");
    }

    var worker = registration.active || registration.waiting || registration.installing;
    if (!worker || worker.state === "activated") {
      return registration;
    }

    await new Promise(function (resolve, reject) {
      var timeout = window.setTimeout(function () {
        reject(new Error("service_worker_activation_timeout"));
      }, 8000);

      worker.addEventListener("statechange", function () {
        if (worker.state === "activated") {
          window.clearTimeout(timeout);
          resolve();
        }
      });
    });

    return registration;
  }

  function isFaceMeetPushRegistration(registration) {
    if (!registration) return false;
    var worker = registration.active || registration.waiting || registration.installing;
    var scriptURL = worker && worker.scriptURL ? worker.scriptURL : "";
    return scriptURL.indexOf("facemeet_web_push_sw.js") !== -1;
  }

  async function unregisterWrongRootRegistration(registration) {
    if (!registration || isFaceMeetPushRegistration(registration)) {
      return false;
    }

    var worker = registration.active || registration.waiting || registration.installing;
    var scriptURL = worker && worker.scriptURL ? worker.scriptURL : "";
    console.warn("WEB PUSH: wrong root service worker found", {
      hasScript: Boolean(scriptURL),
    });

    try {
      var result = await registration.unregister();
      console.info("WEB PUSH: wrong root service worker unregistered", {
        success: Boolean(result),
      });
      return Boolean(result);
    } catch (error) {
      console.warn("WEB PUSH: wrong root service worker unregister failed", {
        name: error && error.name ? error.name : "UnknownError",
      });
      return false;
    }
  }

  async function getPushRegistration(registerIfMissing) {
    var rootRegistration = await navigator.serviceWorker.getRegistration("/");
    if (isFaceMeetPushRegistration(rootRegistration)) {
      return rootRegistration;
    }

    var oldScopedRegistration = await navigator.serviceWorker.getRegistration("/web-push/");
    if (isFaceMeetPushRegistration(oldScopedRegistration)) {
      if (registerIfMissing) {
        await unregisterWrongRootRegistration(rootRegistration);
        await oldScopedRegistration.unregister().catch(function () {});
      } else {
        return oldScopedRegistration;
      }
    } else if (registerIfMissing) {
      await unregisterWrongRootRegistration(rootRegistration);
      if (oldScopedRegistration) {
        await oldScopedRegistration.unregister().catch(function () {});
      }
    }

    if (!registerIfMissing) {
      return null;
    }

    console.info("WEB PUSH: service worker register started");
    var registration = await navigator.serviceWorker.register("/facemeet_web_push_sw.js", {
      scope: "/",
      updateViaCache: "none",
    });
    console.info("WEB PUSH: service worker registered", {
      scope: registration.scope,
    });
    try {
      await registration.update();
    } catch (_) {}
    return registration;
  }

  window.facemeetGetNotificationPermission = function () {
    if (!("Notification" in window)) return "unsupported";
    return Notification.permission;
  };

  window.facemeetIsWebPushSupported = function () {
    return Boolean(
      "Notification" in window &&
        "serviceWorker" in navigator &&
        "PushManager" in window,
    );
  };

  window.facemeetRequestWebPushSubscription = async function (vapidPublicKey) {
    if (!window.facemeetIsWebPushSupported()) {
      console.warn("WEB PUSH: unsupported browser");
      return { error: "unsupported" };
    }

    if (!vapidPublicKey || vapidPublicKey.indexOf("REPLACE_") === 0) {
      console.warn("WEB PUSH: missing VAPID public key");
      return { error: "missing_vapid_public_key" };
    }

    console.info("WEB PUSH: notification permission before request", Notification.permission);
    var permission = await Notification.requestPermission();
    console.info("WEB PUSH: notification permission after request", permission);
    if (permission !== "granted") {
      return { permission: permission };
    }

    try {
      console.info("WEB PUSH: VAPID public key loaded yes");
      var registration = await getPushRegistration(true);
      await waitForPushServiceWorker(registration);
      var isFaceMeetWorker = isFaceMeetPushRegistration(registration);
      console.info("WEB PUSH: service worker ready", {
        scope: registration.scope,
        isFaceMeetWorker: isFaceMeetWorker,
      });

      if (!isFaceMeetWorker) {
        return {
          permission: permission,
          serviceWorkerReady: Boolean(registration),
          isFaceMeetWorker: false,
          error: "wrong_service_worker",
          message: "FaceMeet push worker was not active.",
        };
      }

      var existing = await registration.pushManager.getSubscription();
      console.info("WEB PUSH: pushManager.subscribe started", {
        usingExisting: Boolean(existing),
      });
      var subscription =
        existing ||
        (await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: base64UrlToUint8Array(vapidPublicKey),
        }));

      var json = subscription.toJSON();
      console.info("WEB PUSH: pushManager.subscribe success", {
        endpointPresent: Boolean(json.endpoint),
        p256dhPresent: Boolean(json.keys && json.keys.p256dh),
        authPresent: Boolean(json.keys && json.keys.auth),
        platform: getPlatform(),
      });

      return {
        endpoint: json.endpoint,
        p256dh: json.keys && json.keys.p256dh,
        auth: json.keys && json.keys.auth,
        userAgent: window.navigator.userAgent || "",
        platform: getPlatform(),
        permission: permission,
        serviceWorkerReady: true,
        isFaceMeetWorker: true,
        subscriptionCreated: Boolean(json.endpoint && json.keys && json.keys.p256dh && json.keys.auth),
      };
    } catch (error) {
      console.warn("WEB PUSH: pushManager.subscribe failure", {
        name: error && error.name ? error.name : "UnknownError",
        message: error && error.message ? error.message : "Unknown error",
      });
      return {
        permission: permission,
        serviceWorkerReady: false,
        isFaceMeetWorker: false,
        subscriptionCreated: false,
        error: error && error.name ? error.name : "subscription_failed",
        message: error && error.message ? error.message : "Unknown error",
      };
    }
  };

  window.facemeetGetWebPushSubscriptionStatus = async function () {
    if (!window.facemeetIsWebPushSupported()) {
      return { permission: "unsupported", subscriptionStatus: "unsupported" };
    }
    var permission = Notification.permission;
    if (permission !== "granted") {
      return { permission: permission, subscriptionStatus: "notSubscribed" };
    }
    try {
      var registration = await getPushRegistration(false);
      var subscription = registration
        ? await registration.pushManager.getSubscription()
        : null;
      return {
        permission: permission,
        subscriptionStatus: subscription ? "subscribed" : "notSubscribed",
        serviceWorkerReady: Boolean(registration),
        isFaceMeetWorker: isFaceMeetPushRegistration(registration),
        endpointPresent: Boolean(subscription && subscription.endpoint),
      };
    } catch (error) {
      console.warn("WEB PUSH: subscription status error", error && error.message);
      return { permission: permission, subscriptionStatus: "error" };
    }
  };
})();
