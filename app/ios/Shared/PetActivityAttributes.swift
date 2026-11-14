import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct PetActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var packId: String?
    var phase: String
    /// The app's exact pet state (`juggling`, `sweeping`, ...); nil when only
    /// the Live Activity phase is known (background updates, older activities).
    var petState: String?
    /// The pet's busy tier (`working` 1–3, `juggling` 1–2); nil for none, and
    /// for activities written before the field existed.
    var tier: Int?
    /// One short line under the headline; already masked by the app. nil when
    /// there is nothing more to say (idle, background updates).
    var detail: String?
    /// A stable, meaningless digest of the finished turn: the island picks the
    /// celebration from it, so a redraw keeps the same pose.
    var completionSeed: String?
    /// When the run started (epoch ms), for the chip's own timer; nil when the
    /// phase has nothing to count.
    var since: Int?
    var label: String
    var staleLabel: String
  }

  // Opaque host reference, never a host's credentials or address.
  var host: String
  var sessionId: String

  var url: URL? {
    guard host != "local-pet" else { return nil }
    var parts = URLComponents()
    parts.scheme = "dshgo"
    parts.host = "pet-session"
    parts.queryItems = [URLQueryItem(name: "host", value: host),
                        URLQueryItem(name: "sessionId", value: sessionId)]
    return parts.url
  }
}

/// The chosen pet's art, left by the app where the widget extension can read
/// it. An extension cannot read the app's bundle or its sandbox, so the app
/// copies `pack.json` and the sheets it names into an App Group folder,
/// verbatim, one folder per pack (`<group>/pet-art/<pack id>/`). The widget
/// draws the same cells the app draws, so the island shows the same pet.
enum PetArtStore {
  /// Keep in step with both targets' `.entitlements`.
  static let appGroup = "group.io.github.ccch1mneyyy.dshgo"

  /// `<group>/pet-art`; nil when the group is not in the build's entitlements.
  static func base() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
      .appendingPathComponent("pet-art", isDirectory: true)
  }

  /// `<group>/pet-art/<packId>`; nil for a name that could leave the folder.
  static func directory(_ packId: String) -> URL? {
    guard let base = base(), !packId.isEmpty, packId.count <= 64,
          packId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
    return base.appendingPathComponent(packId, isDirectory: true)
  }
}
