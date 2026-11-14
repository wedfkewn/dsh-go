import ActivityKit
import Flutter
import UIKit

final class PetLiveActivityPlugin: NSObject, FlutterPlugin {
  static var instance: PetLiveActivityPlugin?
  private static var pendingURL: URL?
  private let channel: FlutterMethodChannel
  private var ready = false
  private var background: [String: Any]?
  /// Bumped by every newer truth (a background snapshot, a foreground push).
  /// A task from an older truth stops before it writes a stale pose.
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
        guard let next = self.backgroundState(host: activity.attributes.host,
          session: activity.attributes.sessionId, original: old) else { continue }
        guard version == self.backgroundVersion else { return }
        await activity.update(ActivityContent(state: next,
          staleDate: Date().addingTimeInterval(300)))
      }
    }
  }

  /// The state a background snapshot implies for one activity; nil when the
  /// snapshot says nothing new about it. The snapshot may only refine the
  /// pose: it keeps the activity's `packId`, its exact running animation and
  /// its tier, and it never claims a run stopped (or failed) that it cannot
  /// confirm — an ended background grant reads as 「无法确认」, not as sleep.
  @available(iOS 16.2, *)
  private func backgroundState(host: String, session: String,
    original: PetActivityAttributes.ContentState) -> PetActivityAttributes.ContentState? {
    guard let snapshot = background,
      let data = host.data(using: .utf8),
      let reference = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      reference["kind"] as? String == "local" else { return nil }
    if let observed = snapshot["sessionId"] as? String {
      guard observed == session else { return nil }
    } else if ["idle", "completed", "error", "waitingApproval"].contains(original.phase) {
      // Nothing runs, or the turn already ended: a host-wide snapshot cannot
      // know better than the app's own reducer.
      return nil
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
    // Keep what the app knew when the pose still holds; replace only where the
    // snapshot actually changes it. `authorizationEnded` / `waitingRecovery`
    // mean 「无法确认是否还在跑」, so the pet stays awake and idle-looking
    // rather than pretending to sleep or to have failed.
    let petState: String?
    let tier: Int?
    switch phase {
    case "continuedProcessing", "working":
      petState = Self.runningPetState(original.petState) ?? "working"
      tier = phase == "continuedProcessing" ? original.tier : nil
    case "waitingApproval":
      petState = "notification"; tier = nil
    case "completed":
      petState = "attention"; tier = nil
    case "error":
      petState = "error"; tier = nil
    default:
      petState = "idle"; tier = nil
    }
    let staleKey = ["completed", "error", "waitingApproval"].contains(phase) ? key : "Waiting to resume"
    let next = PetActivityAttributes.ContentState(packId: original.packId, phase: phase,
      petState: petState, tier: tier, detail: nil, completionSeed: nil, since: nil,
      label: NSLocalizedString(key, comment: "Background task status"),
      staleLabel: NSLocalizedString(staleKey, comment: "Background task status"))
    return next == original ? nil : next
  }

  /// An exact animation the app sent, when the background pose can keep it.
  private static func runningPetState(_ petState: String?) -> String? {
    guard let petState else { return nil }
    return ["thinking", "working", "juggling", "sweeping", "carrying"].contains(petState)
      ? petState : nil
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
    // Where the app leaves the chosen pet's art for the widget extension
    // (PetArtStore); created here so Dart writes only files it owns.
    if call.method == "artDirectory" {
      guard let directory = PetArtStore.base() else {
        result(FlutterError(code: "pet_art_unavailable",
          message: "The shared pet art folder is unavailable.", details: nil))
        return
      }
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        result(directory.path)
      } catch {
        result(FlutterError(code: "pet_art_unavailable", message: error.localizedDescription, details: nil))
      }
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
              ["idle", "thinking", "working", "waitingApproval", "completed", "error",
               "continuedProcessing", "authorizationEnded", "waitingRecovery"].contains(phase),
              let label = args["label"] as? String, label.count <= 120,
              let staleLabel = args["staleLabel"] as? String, staleLabel.count <= 120 else {
          result(FlutterError(code: "pet_live_activity_invalid_arguments", message: "Expected host, sessionId, phase and short label/staleLabel strings.", details: nil))
          return
        }
        let petState = (args["petState"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard petState == nil || ["idle", "thinking", "working", "juggling", "sweeping", "carrying",
                                  "notification", "attention", "error", "sleeping", "waking"].contains(petState!) else {
          result(FlutterError(code: "pet_live_activity_invalid_arguments", message: "Unknown pet state.", details: nil))
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
        // A foreground push is the newest truth: the reducer already decided
        // this pose, so no background snapshot may rewrite it.
        backgroundVersion += 1
        let tier = (args["tier"] as? NSNumber).map { max(0, min($0.intValue, 3)) }
        let detail = (args["detail"] as? String).flatMap {
          $0.isEmpty || $0.count > 120 ? nil : $0
        }
        let seed = (args["completionSeed"] as? String).flatMap {
          $0.count == 8 ? $0 : nil
        }
        let since = (args["since"] as? NSNumber).map { $0.intValue }
        let state = PetActivityAttributes.ContentState(packId: args["packId"] as? String,
          phase: phase, petState: petState, tier: tier, detail: detail,
          completionSeed: seed, since: since, label: label, staleLabel: staleLabel)
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
