import Flutter
import UIKit
import UserNotifications

/// iOS implementation of the existing notification contract. No background
/// execution, push entitlement, inline approval or ActivityKit dependency.
final class NotifyPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let center = UNUserNotificationCenter.current()
  private var tapSink: FlutterEventSink?
  private static var pendingTap: [AnyHashable: Any]?
  private static weak var active: NotifyPlugin?

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = NotifyPlugin()
    active = plugin
    registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(
      name: "dsh/notify", binaryMessenger: registrar.messenger()))
    FlutterEventChannel(name: "dsh/notify/taps", binaryMessenger: registrar.messenger())
      .setStreamHandler(plugin)
    FlutterEventChannel(name: "dsh/notify/actions", binaryMessenger: registrar.messenger())
      .setStreamHandler(NoInlineNotifyActions())
    registrar.addApplicationDelegate(plugin)
  }

  private func finish(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private func identifier(_ args: [String: Any]) -> String? {
    guard let group = args["group"] as? String, let key = args["key"] as? String else { return nil }
    // Length-prefixed, so separators in host/session/event IDs cannot collide.
    return "dsh:\(group.utf8.count):\(group)\(key)"
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "status":
      center.getNotificationSettings { settings in
        let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        let alerts = allowed && settings.alertSetting == .enabled
        self.finish(result, ["enabled": alerts, "done": alerts, "attention": alerts])
      }
    case "openSettings":
      // Only this user-initiated operation requests permission. A status read or
      // an incoming chat event never triggers the system prompt.
      center.getNotificationSettings { settings in
        if settings.authorizationStatus == .notDetermined {
          self.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
              self.finish(result, FlutterError(code: "ios_notification_permission_failed",
                message: error.localizedDescription, details: nil))
            } else {
              self.finish(result, granted)
            }
          }
        } else {
          DispatchQueue.main.async {
            guard let url = URL(string: UIApplication.openSettingsURLString) else {
              result(false); return
            }
            UIApplication.shared.open(url, options: [:]) { result($0) }
          }
        }
      }
    case "show":
      guard let id = identifier(args), let group = args["group"] as? String,
            let publicText = args["publicText"] as? String,
            let host = args["host"] as? String, let session = args["sessionId"] as? String else {
        result(FlutterError(code: "ios_notification_invalid_arguments", message: "Missing notification target or content", details: nil))
        return
      }
      center.getNotificationSettings { settings in
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
          self.finish(result, FlutterError(code: "ios_notification_permission_denied", message: "Enable notifications in Settings", details: nil))
          return
        }
        let content = UNMutableNotificationContent()
        content.title = "DSH Go"
        // OS surfaces always show public text. Open the app to read sensitive
        // content or approve; app lock also covers notification navigation.
        content.body = publicText
        content.sound = .default
        content.threadIdentifier = group
        content.userInfo = ["host": host, "sessionId": session]
        for field in ["kind", "eventId"] {
          if let value = args[field] as? String { content.userInfo[field] = value }
        }
        self.center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
          self.finish(result, error.map {
            FlutterError(code: "ios_notification_delivery_failed", message: $0.localizedDescription, details: nil)
          })
        }
      }
    case "cancel":
      guard let id = identifier(args) else {
        result(FlutterError(code: "ios_notification_invalid_arguments", message: "Missing group or key", details: nil)); return
      }
      center.removeDeliveredNotifications(withIdentifiers: [id])
      center.removePendingNotificationRequests(withIdentifiers: [id])
      result(nil)
    case "cancelGroup":
      guard let group = args["group"] as? String else {
        result(FlutterError(code: "ios_notification_invalid_arguments", message: "Missing group", details: nil)); return
      }
      center.getDeliveredNotifications { notifications in
        self.center.removeDeliveredNotifications(withIdentifiers: notifications.filter {
          $0.request.content.threadIdentifier == group
        }.map { $0.request.identifier })
        self.center.getPendingNotificationRequests { requests in
          self.center.removePendingNotificationRequests(withIdentifiers: requests.filter {
            $0.content.threadIdentifier == group
          }.map { $0.identifier })
          self.finish(result, nil)
        }
      }
    case "cancelAll":
      center.removeAllDeliveredNotifications()
      center.removeAllPendingNotificationRequests()
      result(nil)
    case "actionResult":
      result(FlutterError(code: "ios_notification_inline_approval_unimplemented",
        message: "Open the app to answer approvals", details: nil))
    case "liveStatus":
      // Stage 5 owns iOS activities through its separate pet channel.
      result(["supported": false, "allowed": false, "settings": false])
    case "live", "openLiveSettings":
      result(FlutterError(code: "ios_android_live_notification_unimplemented",
        message: "Android live notifications are unavailable on iOS; use the pet activity channel", details: nil))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    tapSink = events
    if let tap = Self.pendingTap { Self.pendingTap = nil; events(tap) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    tapSink = nil
    return nil
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void) {
    Self.open(response)
    completionHandler()
  }

  /// UIScene supplies the response on a cold launch before the Dart listener.
  static func open(_ response: UNNotificationResponse) {
    let tap = response.notification.request.content.userInfo
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
          response.notification.request.identifier.hasPrefix("dsh:"),
          tap["host"] is String, tap["sessionId"] is String else { return }
    DispatchQueue.main.async {
      if let sink = active?.tapSink { sink(tap) } else { pendingTap = tap }
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    guard notification.request.identifier.hasPrefix("dsh:") else { completionHandler([]); return }
    completionHandler([.banner, .sound])
  }
}

private final class NoInlineNotifyActions: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { nil }
}
