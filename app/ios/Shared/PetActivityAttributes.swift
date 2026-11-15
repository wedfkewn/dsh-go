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
    /// A small transparent PNG for this exact pose, rendered by the Flutter
    /// app. It is the only art source an imported pet has when a sideloaded
    /// build has no App Group; old activities simply decode it as nil.
    var art: Data? = nil
    /// Inline art window height divided by the pack body height.
    var artBodyRatio: Double? = nil
    /// Inline art was authored as pixel art and must not be smoothed.
    var artPixelArt: Bool? = nil
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

/// Fallback art locations for older activities and copied packs. An extension
/// cannot read the app's bundle or its sandbox, so the app copies `pack.json`
/// and the sheets it names into an App Group folder, verbatim, one folder per
/// pack (`<group>/pet-art/<pack id>/`). New updates also carry a tiny inline
/// still in `ContentState`, which is what imported pets use when the App Group
/// is unavailable.
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
    guard let base = base() else { return nil }
    return folder(in: base, named: packId)
  }

  /// `pets/<packId>`: the built-in packs the appex carries as a folder
  /// reference. A sideloaded build has no App Group at all (the
  /// entitlement is stripped when the profile does not authorize it), so
  /// without this the island could only ever show an emoji for the pets the
  /// app ships with.
  static func bundled(_ packId: String) -> URL? {
    guard let root = Bundle.main.resourceURL?
      .appendingPathComponent("pets", isDirectory: true) else { return nil }
    return folder(in: root, named: packId)
  }

  /// Where this pack can be read: the copy the app staged in the App Group
  /// first (it is the one that matches the pet the user picked, including an
  /// imported one), then the built-in copy in this bundle. Empty when neither
  /// holds a `pack.json`; new activities also carry inline art, and only an
  /// older activity without that fallback keeps its emoji.
  static func candidates(_ packId: String) -> [URL] {
    var seen: Set<String> = []
    return [directory(packId), bundled(packId)].compactMap({ $0 }).filter { url in
      let file = url.appendingPathComponent("pack.json")
      guard FileManager.default.fileExists(atPath: file.path) else { return false }
      return seen.insert(url.path).inserted
    }
  }

  /// `<root>/<packId>`; nil for a name that could leave the folder.
  private static func folder(in root: URL, named packId: String) -> URL? {
    guard !packId.isEmpty, packId.count <= 64,
          packId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
    return root.appendingPathComponent(packId, isDirectory: true)
  }
}
