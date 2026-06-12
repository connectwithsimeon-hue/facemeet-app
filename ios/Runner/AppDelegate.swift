import Flutter
import UIKit
import AVFoundation
import Firebase
import FirebaseInstallations
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // Configure Firebase FIRST — required for APNs-to-FCM token swizzling
    FirebaseApp.configure()
    print("[PUSH DEBUG] FirebaseApp.configure() called")

    // Set notification delegate so foreground notifications are handled
    UNUserNotificationCenter.current().delegate = self
    print("[PUSH DEBUG] UNUserNotificationCenter delegate set")

    // Explicitly register for remote notifications on the main thread.
    // This is required to trigger APNs token generation.
    // Firebase swizzling will forward the APNs token to FCM automatically.
    DispatchQueue.main.async {
      print("[PUSH DEBUG] registerForRemoteNotifications called")
      UIApplication.shared.registerForRemoteNotifications()
    }

    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback,
        mode: .default,
        options: [.mixWithOthers]
      )
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("AVAudioSession configuration error: \(error)")
    }

    GeneratedPluginRegistrant.register(with: self)

    // Set up Flutter method channel for push notification debug operations
    if let controller = window?.rootViewController as? FlutterViewController {
      let pushChannel = FlutterMethodChannel(
        name: "com.ononobi.facemeet/push",
        binaryMessenger: controller.binaryMessenger
      )
      pushChannel.setMethodCallHandler { [weak self] (call, result) in
        switch call.method {
        case "registerForRemoteNotifications":
          print("[PUSH DEBUG] Native: registerForRemoteNotifications called via method channel")
          DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
          }
          result(nil)

        case "deleteFirebaseInstallation":
          print("[PUSH DEBUG] Native: deleteFirebaseInstallation called via method channel")
          Installations.installations().delete { error in
            if let error = error {
              print("[PUSH DEBUG] Native: Firebase Installation delete error: \(error.localizedDescription)")
              // Non-fatal — return nil so Flutter side can continue
              result(nil)
            } else {
              print("[PUSH DEBUG] Native: Firebase Installation ID deleted successfully")
              result(nil)
            }
          }

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - UNUserNotificationCenterDelegate

  // Show notifications (alert, badge, sound) while app is in the foreground
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    print("[PUSH DEBUG] Foreground notification received: \(notification.request.identifier)")
    completionHandler([.alert, .badge, .sound])
  }

  // Handle notification tap
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    print("[PUSH DEBUG] Notification tapped: \(response.notification.request.identifier)")
    completionHandler()
  }

  // MARK: - APNs Registration Callbacks

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    print("[PUSH DEBUG] didRegisterForRemoteNotifications called")
    print("[PUSH DEBUG] APNs token received exists=true length=\(deviceToken.count)")
    // Firebase swizzling is ENABLED — it automatically forwards the APNs token to FCM.
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    print("[PUSH DEBUG] didFailToRegisterForRemoteNotifications error=\(error.localizedDescription)")
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }
}
