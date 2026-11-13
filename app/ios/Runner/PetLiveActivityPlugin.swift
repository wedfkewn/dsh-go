import ActivityKit
import Flutter
import UIKit

final class PetLiveActivityPlugin: NSObject, FlutterPlugin {
  static var instance: PetLiveActivityPlugin?
  private static var pendingURL: URL?
  private let channel: FlutterMethodChannel
  private var ready = false
  private var background: [String: Any]?
  private var backgroundVersion = 0

  @objc private func backgroundChanged(_ notification: Notification) {
    background = notification.userInfo as? [String: Any]
    backgroundVersion += 1
    let version = backgroundVersion
    guard #available(iOS 16.2, *) else { return }
    Task { @MainActor in
      for activity in Activity<PetActivityAttributes>.activities {
        guard version == self.backgroundVersion else { return }
        let old = activity.content.state
        let next = self.backgroundContent(host: activity.attributes.host,
          session: activity.attributes.sessionId, original: old)
        if next != old {
          await activity.update(ActivityContent(state: next, staleDate: Date().addingTimeInterval(300)))
        }
      }
    }
  }

  @available(iOS 16.2, *)
  private func backgroundContent(host: String, session: String,
    original: PetActivityAttributes.ContentState) -> PetActivityAttributes.ContentState {
    guard let snapshot = background,
      let data = host.data(using: .utf8),
      let reference = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      reference["kind"] as? String == "local" else { return original }
    if let observed = snapshot["sessionId"] as? String, observed != session { return original }
    if snapshot["sessionId"] as? String == nil && ["idle", "completed", "error"].contains(original.phase) {
      return original
    }
    let task = snapshot["taskState"] as? String
    let state = snapshot["state"] as? String
    let phase: String
    let key: String
    if state == "expired" {
      phase = "authorizationEnded"; key = "Background authorization ended"
    } else if state == "failed" || state == "suspendedOrUnknown" || state == "backgroundGrace" ||
                state == "resuming" || snapshot["taskVerified"] as? Bool != true {
      phase = "waitingRecovery"; key = "Waiting to resume"
    } else if task == "completed" {
      phase = "completed"; key = "Task completed"
    } else if task == "error" {
      phase = "error"; key = "Task failed or canceled"
    } else if task == "waitingApproval" {
      phase = "waitingApproval"; key = "Waiting for approval"
    } else if state == "continuedProcessing" && task == "running" {
      phase = "continuedProcessing"; key = "Continuing in background"
    } else if state == "foreground" && task == "running" {
      phase = "working"; key = "Task running"
    } else {
      phase = "waitingRecovery"; key = "Waiting to resume"
    }
    return PetActivityAttributes.ContentState(packId: original.packId, phase: phase,
      label: NSLocalizedString(key, comment: "Background task status"),
      staleLabel: NSLocalizedString("Waiting to resume", comment: "Background task status"))
  }

  deinit { NotificationCenter.default.removeObserver(self) }
  // Set after request/update; cleared by end or replaced by a new target.
  // If it disappears from ActivityKit, do not recreate it on each reducer tick.
  private var target: String?

  init(channel: FlutterMethodChannel) { self.channel = channel }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dsh/pet_live_activity", binaryMessenger: registrar.messenger())
    let plugin = PetLiveActivityPlugin(channel: channel)
    if let previous = instance { NotificationCenter.default.removeObserver(previous) }
    instance = plugin
    NotificationCenter.default.addObserver(plugin, selector: #selector(backgroundChanged(_:)),
      name: Notification.Name("DshBackgroundExecutionChanged"), object: nil)
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  static func open(_ url: URL) {
    guard url.scheme == "dshgo", url.host == "pet-session" else { return }
    pendingURL = url
    instance?.deliverURL()
  }

  private func deliverURL() {
    guard ready, let url = Self.pendingURL else { return }
    Self.pendingURL = nil
    channel.invokeMethod("link", arguments: ["uri": url.absoluteString])
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "ready" {
      ready = true
      deliverURL()
      result(nil)
      return
    }
    guard ["start", "update", "end"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard #available(iOS 16.2, *) else {
      result(FlutterError(code: "pet_live_activity_unsupported", message: "Live Activities require iOS/iPadOS 16.2 or later and system support.", details: nil))
      return
    }
    Task { @MainActor in
      do {
        if call.method == "end" {
          for activity in Activity<PetActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
          }
          self.target = nil
          result("ended")
          return
        }
        guard let args = call.arguments as? [String: Any],
              let host = args["host"] as? String, !host.isEmpty,
              let session = args["sessionId"] as? String, !session.isEmpty,
              let phase = args["phase"] as? String,
              ["idle", "thinking", "working", "waitingApproval", "completed", "error"].contains(phase),
              let label = args["label"] as? String, label.count <= 120,
              let staleLabel = args["staleLabel"] as? String, staleLabel.count <= 120 else {
          result(FlutterError(code: "pet_live_activity_invalid_arguments", message: "Expected host, sessionId, phase and short label/staleLabel strings.", details: nil))
          return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
          result(FlutterError(code: "pet_live_activity_disabled", message: "Live Activities are unavailable or disabled in system settings.", details: nil))
          return
        }
        let key = host + "\u{0}" + session
        let activities = Activity<PetActivityAttributes>.activities
        let current = activities.first { $0.attributes.host == host && $0.attributes.sessionId == session }
        for activity in activities where activity.id != current?.id {
          await activity.end(nil, dismissalPolicy: .immediate)
        }
        let state = self.backgroundContent(host: host, session: session, original:
          PetActivityAttributes.ContentState(packId: args["packId"] as? String, phase: phase, label: label, staleLabel: staleLabel))
        // A suspended Dart process cannot promise fresh status indefinitely.
        // A local idle pet has no session status that can become stale.
        let content = ActivityContent(state: state, staleDate: host == "local-pet" ? nil : Date().addingTimeInterval(300))
        if let activity = current, activity.activityState == .active || activity.activityState == .stale {
          let changed = activity.content.state.phase != state.phase
          let alert: AlertConfiguration? = changed && ["waitingApproval", "completed", "error"].contains(state.phase)
            ? AlertConfiguration(title: "dsh-Go", body: LocalizedStringResource(stringLiteral: state.label), sound: .default) : nil
          if activity.content.state != state { await activity.update(content, alertConfiguration: alert) }
          self.target = key
          result("updated")
        } else if self.target == key {
          result(FlutterError(code: "pet_live_activity_dismissed", message: "The activity ended or was dismissed. A new target or disabling and re-enabling live updates allows a new activity.", details: nil))
        } else {
          guard UIApplication.shared.applicationState == .active else {
            result(FlutterError(code: "pet_live_activity_requires_foreground", message: "Open the app to start a Live Activity.", details: nil))
            return
          }
          _ = try Activity.request(attributes: PetActivityAttributes(host: host, sessionId: session), content: content, pushType: nil)
          self.target = key
          result("started")
        }
      } catch {
        result(FlutterError(code: "pet_live_activity_request_failed", message: error.localizedDescription, details: nil))
      }
    }
  }
}
