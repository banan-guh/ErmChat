import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Mention push through ermchat-notify (lib/services/apns_push.dart).
  private var apnsChannel: FlutterMethodChannel?
  private var tokenResults: [FlutterResult] = []
  private var launchChannel: String?
  private var dartReady = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "ErmchatApns") {
      let channel = FlutterMethodChannel(
        name: "ermchat/apns", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result: result)
      }
      apnsChannel = channel
    }
    // FlutterAppDelegate forwards what it doesn't handle to the plugins,
    // so local notifications keep working.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "token":
      let prompt = (call.arguments as? [String: Any])?["prompt"] as? Bool ?? false
      tokenResults.append(result)
      if prompt {
        UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .sound, .badge]
        ) { _, _ in
          // The token comes either way; without permission alerts just
          // don't show.
          DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
          }
        }
      } else {
        UIApplication.shared.registerForRemoteNotifications()
      }
    case "blocked":
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        let denied = settings.authorizationStatus == .denied
        DispatchQueue.main.async { result(denied) }
      }
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    case "takeLaunchChannel":
      dartReady = true
      result(launchChannel)
      launchChannel = nil
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func finishToken(_ token: String?) {
    let results = tokenResults
    tokenResults = []
    for result in results { result(token) }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    finishToken(deviceToken.map { String(format: "%02x", $0) }.joined())
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  // Without the push entitlement (unsigned or sideloaded builds) this is
  // where registration ends; the app then never registers with the proxy.
  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    finishToken(nil)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  // The open app shows the mention in chat, so a pushed one stays quiet.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if notification.request.content.userInfo["ermchat_channel"] != nil {
      completionHandler([])
      return
    }
    super.userNotificationCenter(
      center, willPresent: notification, withCompletionHandler: completionHandler)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    guard
      let channel = response.notification.request.content.userInfo["ermchat_channel"]
        as? String
    else {
      super.userNotificationCenter(
        center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }
    // A cold launch lands here before Dart listens; it asks for this later.
    if dartReady {
      apnsChannel?.invokeMethod("tap", arguments: channel)
    } else {
      launchChannel = channel
    }
    completionHandler()
  }
}
