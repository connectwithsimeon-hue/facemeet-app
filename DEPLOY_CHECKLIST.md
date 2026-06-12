# FaceMeet PWA Production Deploy Checklist

## Required Flutter build command

Always build with the VAPID public key:

```bash
flutter build web --release --no-tree-shake-icons --pwa-strategy=none --dart-define=VAPID_PUBLIC_KEY=BIv-HyY1WY42is0EMGVla-vgZ9MYIbjT_3oPXlVhJik2FFaFqB6SjMR91EXweUf3PRbm9aRbJnb60jMAO9-trNA
```

## Required bootstrap patch

After every Flutter web build, open:

```text
build/web/flutter_bootstrap.js
```

Replace:

```js
_flutter.loader.load();
```

With:

```js
_flutter.loader.load({ serviceWorkerSettings: null });
```

## Required push asset checks

Before deploying, confirm these files exist:

```text
build/web/facemeet_web_push_sw.js
build/web/facemeet_web_push.js
```

## Required production verification

Before declaring deploy complete, confirm:

```text
https://app.facemeet.app/facemeet_web_push_sw.js
```

loads JavaScript successfully.

Confirm:

```text
https://app.facemeet.app/flutter_bootstrap.js
```

contains:

```js
_flutter.loader.load({ serviceWorkerSettings: null });
```

## Required smoke test after deploy

Test one installed Android PWA:

* Log in
* Tap Enable Notifications
* Confirm notification permission prompt appears
* Confirm user enters app
* Send Test Notification

Test one installed iPhone PWA:

* Log in
* Tap Enable Notifications
* Confirm notification permission prompt appears
* Confirm user enters app
* Send Test Notification

## Critical warning

Never deploy a newly generated `build/web` folder unless:

* VAPID dart-define was included
* bootstrap patch was restored
* custom push service-worker files exist
* Android and iPhone notification onboarding were smoke-tested
