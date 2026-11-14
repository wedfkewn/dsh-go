import ActivityKit
import ImageIO
import OSLog
import SwiftUI
import WidgetKit

@main
struct PetLiveActivityBundle: WidgetBundle {
  var body: some Widget { PetLiveActivity() }
}

struct PetLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: PetActivityAttributes.self) { context in
      LockScreenCard(context: context)
        .activityBackgroundTint(Palette.background)
        .activitySystemActionForegroundColor(Palette.primary)
        .widgetURL(context.attributes.url)
    } dynamicIsland: { context in
      DynamicIsland {
        // Expanded reads as one row — pet on the left, the state's headline on
        // the right — with the redacted detail as a second line underneath.
        // Keeping the headline beside the pet leaves no dead space on the
        // right of the island and keeps text off its bottom edge.
        DynamicIslandExpandedRegion(.leading) {
          PetSprite(state: context.state, label: compactLabel(context),
            bodyHeight: 34, maxHeight: 46)
            .frame(width: 60, height: 48, alignment: .center)
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          // One line, never stacked: "思考中 …" while it thinks, "干活中
          // 02:41" while it works. The mark reads as part of the sentence
          // instead of floating under it.
          HStack(spacing: 6) {
            Text(headline(context))
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(PhaseStyle.of(context.state.phase).tint)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            CompactStatus(state: context.state, stale: context.isStale,
              label: compactLabel(context))
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
          .padding(.trailing, 6)
        }
        DynamicIslandExpandedRegion(.bottom) {
          if let detail = context.state.detail, !detail.isEmpty {
            Text(detail)
              .font(.system(size: 12))
              .foregroundStyle(Palette.secondary)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 8)
              .padding(.top, 1)
          }
        }
      } compactLeading: {
        // The pet alone, centred in the system pill. Compact has one line of
        // room: a fixed box keeps the sprite off the corner and clips it, so
        // nothing can spill onto the wallpaper beside the island.
        PetSprite(state: context.state, label: compactLabel(context),
          bodyHeight: 16, maxHeight: 22)
          .frame(width: 30, height: 24, alignment: .center)
          .clipped()
      } compactTrailing: {
        CompactStatus(state: context.state, stale: context.isStale, label: compactLabel(context))
          .frame(minWidth: 20, maxHeight: 24, alignment: .center)
      } minimal: {
        // The one thing worth recognizing at a glance.
        MinimalPet(state: context.state, label: compactLabel(context))
          .frame(height: 20, alignment: .center)
      }
      .widgetURL(context.attributes.url)
      .keylineTint(PhaseStyle.of(context.state.phase).tint)
    }
  }

  private func compactLabel(_ context: ActivityViewContext<PetActivityAttributes>) -> String {
    context.isStale ? context.state.staleLabel : context.state.label
  }

  private func headline(_ context: ActivityViewContext<PetActivityAttributes>) -> String {
    context.isStale ? context.state.staleLabel : context.state.label
  }
}

/// The lock screen's card: the pet, then the headline and one line of detail.
/// Same black surface and palette as the island, so the two read as one thing.
private struct LockScreenCard: View {
  let context: ActivityViewContext<PetActivityAttributes>

  private var text: String { context.isStale ? context.state.staleLabel : context.state.label }

  var body: some View {
    HStack(spacing: 14) {
      PetSprite(state: context.state, label: text, bodyHeight: 34, maxHeight: 44)
        .frame(width: 52, alignment: .center)
      VStack(alignment: .leading, spacing: 3) {
        Text(text)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(PhaseStyle.of(context.state.phase).tint)
          .lineLimit(1)
        if let detail = context.state.detail {
          Text(detail)
            .font(.system(size: 13))
            .foregroundStyle(Palette.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      PhaseGlyph(style: PhaseStyle.of(context.state.phase), size: 16)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
  }
}

// MARK: - Palette

/// The one palette of docs/design: a black surface, quiet greys, and colour
/// only where it tells waiting from working from done from failed.
private enum Palette {
  static let background = Color.black
  static let primary = Color(red: 0.961, green: 0.961, blue: 0.969)   // #F5F5F7
  static let secondary = Color(red: 0.596, green: 0.596, blue: 0.616) // #98989D
  static let active = Color(red: 0.725, green: 0.647, blue: 0.961)    // #B9A5F5
  static let success = Color(red: 0.525, green: 0.851, blue: 0.667)   // #86D9AA
  static let waiting = Color(red: 0.957, green: 0.733, blue: 0.471)   // #F4BB78
  static let failure = Color(red: 0.945, green: 0.549, blue: 0.569)   // #F18C91
}

/// What one phase looks like: its colour, and the single symbol (if any) that
/// belongs beside it. Idle and thinking carry no symbol — the pet says it.
private struct PhaseStyle {
  let tint: Color
  let symbol: String?

  static func of(_ phase: String) -> PhaseStyle {
    switch phase {
    case "thinking": return PhaseStyle(tint: Palette.secondary, symbol: nil)
    case "working", "continuedProcessing": return PhaseStyle(tint: Palette.active, symbol: nil)
    case "waitingApproval": return PhaseStyle(tint: Palette.waiting, symbol: "hand.raised.fill")
    case "authorizationEnded": return PhaseStyle(tint: Palette.waiting, symbol: "pause.circle.fill")
    case "waitingRecovery": return PhaseStyle(tint: Palette.waiting, symbol: "clock.badge.exclamationmark")
    case "completed": return PhaseStyle(tint: Palette.success, symbol: "checkmark.circle.fill")
    case "error": return PhaseStyle(tint: Palette.failure, symbol: "exclamationmark.triangle.fill")
    default: return PhaseStyle(tint: Palette.secondary, symbol: nil)
    }
  }
}

private struct PhaseGlyph: View {
  let style: PhaseStyle
  let size: CGFloat

  var body: some View {
    if let symbol = style.symbol {
      Image(systemName: symbol)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(style.tint)
    }
  }
}

/// The island's trailing side: one thing only. A running task counts up; a
/// waiting turn shows its mark; a finished one its check. Nothing at all while
/// the pet idles, so the collapsed island stays quiet.
private struct CompactStatus: View {
  let state: PetActivityAttributes.ContentState
  let stale: Bool
  let label: String

  var body: some View {
    if stale {
      Image(systemName: "clock.badge.exclamationmark")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Palette.waiting)
        .accessibilityLabel(label)
    } else if state.phase == "working" || state.phase == "continuedProcessing" {
      if let start = self.start {
        timer(start)
      } else {
        Circle()
          .fill(Palette.active)
          .frame(width: 5, height: 5)
          .accessibilityLabel(label)
      }
    } else if state.phase == "thinking" {
      Image(systemName: "ellipsis")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Palette.secondary)
        .accessibilityLabel(label)
    } else {
      PhaseGlyph(style: PhaseStyle.of(state.phase), size: 15)
        .accessibilityLabel(label)
    }
  }

  private var start: Date? {
    guard let ms = state.since, ms > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
  }

  private func timer(_ start: Date) -> some View {
    Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: false)
      .font(.system(size: 12, weight: .medium))
      .monospacedDigit()
      .foregroundStyle(PhaseStyle.of(state.phase).tint)
      .lineLimit(1)
      .accessibilityLabel(label)
  }
}

/// Minimal: just the pet, at the largest size that still reads as the character.
private struct MinimalPet: View {
  let state: PetActivityAttributes.ContentState
  let label: String

  var body: some View {
    // At this size an action prop would squeeze the body into a few pixels.
    // Keep the selected character recognisable instead of shrinking the whole
    // prop-heavy action window into the Minimal region.
    PetSprite(state: idleState, label: label, bodyHeight: 14, maxHeight: 18)
      .frame(width: 22, alignment: .center)
  }

  private var idleState: PetActivityAttributes.ContentState {
    PetActivityAttributes.ContentState(packId: state.packId, phase: "idle",
      petState: "idle", tier: nil, detail: nil, completionSeed: nil, since: nil,
      label: label, staleLabel: label)
  }
}

// MARK: - The pet

/// The chosen pet, drawn from its own sheet: the cell the pack names as that
/// animation's representative frame, at the animation's own box, scaled by the
/// body the pack declares. One window per animation (the body plus the props
/// that animation draws), never one giant canvas for every state.
private struct PetSprite: View {
  let state: PetActivityAttributes.ContentState
  let label: String
  let bodyHeight: CGFloat
  let maxHeight: CGFloat

  var body: some View {
    if let art = PetArt.sprite(packId: state.packId, phase: state.phase,
      petState: state.petState, tier: state.tier, seed: state.completionSeed,
      bodyHeight: bodyHeight, maxHeight: maxHeight) {
      art.image
        .resizable()
        .interpolation(.none)
        .frame(width: art.draw.width, height: art.draw.height)
        .offset(x: art.offset.width, y: art.offset.height)
        .frame(width: art.frame.width, height: art.frame.height, alignment: .topLeading)
        .clipped()
        .accessibilityLabel(label)
    } else {
      // Only a pack that is not there at all falls back to this; the reason is
      // logged (PetArt) rather than hidden behind the emoji.
      Text(Emoji.face(packId: state.packId, phase: state.phase))
        .font(.system(size: bodyHeight))
        .minimumScaleFactor(0.5)
        .lineLimit(1)
        .accessibilityLabel(label)
    }
  }
}

/// The pet's own still, in points: [draw] is the cropped cell placed at
/// [offset] inside a window of [frame].
struct PetArtwork {
  let image: Image
  let draw: CGSize
  let offset: CGSize
  let frame: CGSize
}

/// Reads what the app staged in the App Group (`PetArtStore`): the pack's
/// `pack.json` plus the sheets it names, exactly as the app draws them.
enum PetArt {
  private static let log = Logger(subsystem: "io.github.ccch1mneyyy.dshApp",
    category: "pet-live-activity")

  private struct Animation {
    let sheet: String
    let frameWidth: Int
    let frameHeight: Int
    let cols: Int
    let box: CGRect
    let cells: [Int]
    /// The pack's chosen still, when it names a cell this animation plays.
    let preview: Int?
  }

  private struct Tier {
    let min: Int
    let anim: String
  }

  private struct Bonus {
    let anims: [String]
    let chance: Double
  }

  private struct Pack {
    /// The idle body, art pixels: the one measure everything scales by.
    let body: CGRect
    /// State name → its animations, first one main.
    let states: [String: [String]]
    let animations: [String: Animation]
    /// Busy state → tiers, highest first (the app's own table).
    let tiers: [String: [Tier]]
    /// State name → an occasional alternative (attention's extras).
    let bonus: [String: Bonus]
  }

  private static var packs: [String: (stamp: String, pack: Pack)] = [:]
  private static var sheets: [String: CGImage] = [:]
  private static var logged: Set<String> = []

  static func sprite(packId: String?, phase: String, petState: String?, tier: Int?,
    seed: String?, bodyHeight: CGFloat, maxHeight: CGFloat) -> PetArtwork? {
    guard let packId, bodyHeight > 0, maxHeight > 0,
          let directory = PetArtStore.directory(packId) else {
      note(packId, "pack_not_staged")
      return nil
    }
    guard let pack = read(packId, directory) else { return nil }
    guard let name = animationName(pack, phase: phase, petState: petState,
      tier: tier, seed: seed) ?? pack.states["idle"]?.first,
          let animation = pack.animations[name] else {
      note(packId, "animation_missing")
      return nil
    }
    guard animation.frameWidth > 0, animation.frameHeight > 0, animation.cols > 0,
          !animation.cells.isEmpty else {
      note(packId, "animation_empty")
      return nil
    }
    guard let sheet = image(packId, animation.sheet, directory) else { return nil }
    let index = animation.preview.flatMap { animation.cells.contains($0) ? $0 : nil }
      ?? animation.cells[(animation.cells.count - 1) / 2]
    let cell = CGRect(x: CGFloat(index % animation.cols * animation.frameWidth),
                      y: CGFloat(index / animation.cols * animation.frameHeight),
                      width: CGFloat(animation.frameWidth), height: CGFloat(animation.frameHeight))
      .intersection(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
    guard cell.width >= 1, cell.height >= 1, let cropped = sheet.cropping(to: cell) else {
      note(packId, "cell_out_of_sheet")
      return nil
    }
    // This animation's own window: the body it draws plus whatever props it
    // adds (keyboard, hat, thinking cloud). Nothing else widens it, so the pet
    // keeps its size across states without shrinking into a shared canvas.
    let window = animation.box.union(pack.body)
    guard window.width > 0, window.height > 0 else { return nil }
    let scale = min(bodyHeight / pack.body.height, maxHeight / window.height)
    return PetArtwork(
      image: Image(decorative: cropped, scale: 1),
      draw: CGSize(width: animation.box.width * scale, height: animation.box.height * scale),
      offset: CGSize(width: (animation.box.minX - window.minX) * scale,
        height: (animation.box.minY - window.minY) * scale),
      frame: CGSize(width: window.width * scale, height: window.height * scale))
  }

  /// The pack state a phase stands for, at the tier the app plays: the same
  /// table as `PetPack.animFor` in Dart, so island and app never disagree.
  private static func animationName(_ pack: Pack, phase: String, petState: String?,
    tier: Int?, seed: String?) -> String? {
    if phase == "completed", let celebration = celebration(pack, seed: seed) {
      return celebration
    }
    let state: String = switch phase {
    case "thinking": "thinking"
    case "working", "continuedProcessing": "working"
    case "waitingApproval": "notification"
    case "completed": "attention"
    case "error": "error"
    case "authorizationEnded", "waitingRecovery": "idle"
    default: "idle"
    }
    if let tier, tier > 0 {
      for step in pack.tiers[state] ?? [] where tier >= step.min {
        if pack.animations[step.anim] != nil { return step.anim }
      }
    }
    if let petState, allows(petState, phase: phase), let name = pack.states[petState]?.first,
       pack.animations[name] != nil {
      return name
    }
    return pack.states[state]?.first
  }

  /// A finished turn's occasional extra pose (`bonus.attention`), picked from
  /// the turn's own seed: the same turn always celebrates the same way.
  private static func celebration(_ pack: Pack, seed: String?) -> String? {
    guard let bonus = pack.bonus["attention"], let seed, !bonus.anims.isEmpty else { return nil }
    let roll = Double(hash(seed) % 1000) / 1000
    guard roll < bonus.chance else { return nil }
    let anims = bonus.anims.filter { pack.animations[$0] != nil }
    guard !anims.isEmpty else { return nil }
    return anims[Int(hash(seed + "/pick") % UInt64(anims.count))]
  }

  private static func hash(_ text: String) -> UInt64 {
    var value: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 {
      value = (value ^ UInt64(byte)) &* 0x100000001b3
    }
    return value
  }

  /// A state the app sends may name its exact animation; only accept it when it
  /// still belongs to the phase, so a stale background update cannot lie.
  private static func allows(_ petState: String, phase: String) -> Bool {
    switch phase {
    case "working", "continuedProcessing":
      return ["working", "juggling", "sweeping", "carrying", "thinking"].contains(petState)
    case "thinking": return petState == "thinking"
    case "waitingApproval": return petState == "notification"
    case "completed": return petState == "attention"
    case "error": return petState == "error"
    default: return petState == "idle"
    }
  }

  private static func read(_ packId: String, _ directory: URL) -> Pack? {
    let stamp = (try? String(contentsOf: directory.appendingPathComponent("stamp"), encoding: .utf8)) ?? ""
    if let cached = packs[packId], cached.stamp == stamp { return cached.pack }
    // A re-import can reuse a pack id with different bytes. Its stamp changes,
    // so drop that pack's images before reading the replacement sheets.
    sheets = sheets.filter { !$0.key.hasPrefix(packId + "/") }
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("pack.json")),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let pack = pack(json) else {
      note(packId, "pack_unreadable")
      return nil
    }
    packs[packId] = (stamp, pack)
    return pack
  }

  private static func pack(_ json: [String: Any]) -> Pack? {
    guard let body = rect(json["contentBox"]),
          let raw = json["animations"] as? [String: [String: Any]] else { return nil }
    var states: [String: [String]] = [:]
    for (state, names) in (json["states"] as? [String: [Any]]) ?? [:] {
      states[state] = names.compactMap { $0 as? String }
    }
    var parsed: [String: Animation] = [:]
    for (name, value) in raw {
      guard let sheet = value["sheet"] as? String, !sheet.isEmpty, !sheet.contains("/"),
            let frameWidth = number(value["frameW"]), let frameHeight = number(value["frameH"]),
            let cols = number(value["cols"]), cols > 0, let box = rect(value["box"]) else { continue }
      parsed[name] = Animation(sheet: sheet, frameWidth: frameWidth, frameHeight: frameHeight,
        cols: cols, box: box,
        cells: (value["frames"] as? [[String: Any]] ?? []).compactMap { number($0["i"]) },
        preview: number(value["preview"]))
    }
    guard !parsed.isEmpty else { return nil }
    var tiers: [String: [Tier]] = [:]
    for (state, steps) in (json["tiers"] as? [String: [Any]]) ?? [:] {
      tiers[state] = (steps.compactMap { $0 as? [String: Any] }).compactMap { step in
        guard let anim = step["anim"] as? String else { return nil }
        return Tier(min: number(step["min"]) ?? 1, anim: anim)
      }.sorted { $0.min > $1.min }
    }
    var bonus: [String: Bonus] = [:]
    for (state, value) in (json["bonus"] as? [String: [String: Any]]) ?? [:] {
      guard let anims = value["anims"] as? [String] else { continue }
      let chance = (value["chance"] as? NSNumber)?.doubleValue ?? 0
      bonus[state] = Bonus(anims: anims, chance: chance)
    }
    return Pack(body: body, states: states, animations: parsed, tiers: tiers, bonus: bonus)
  }

  private static func image(_ packId: String, _ sheet: String, _ directory: URL) -> CGImage? {
    let key = packId + "/" + sheet
    if let cached = sheets[key] { return cached }
    let url = directory.appendingPathComponent(sheet)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      note(packId, "sheet_unreadable")
      return nil
    }
    if sheets.count >= 3 { sheets.removeAll() }
    sheets[key] = image
    return image
  }

  /// One non-sensitive line per pack and reason, so a missing App Group, a
  /// half-copied pack or an undecodable sheet is visible in Console instead of
  /// hiding behind the emoji fallback forever.
  private static func note(_ packId: String?, _ reason: String) {
    let key = (packId ?? "none") + "/" + reason
    guard !logged.contains(key) else { return }
    logged.insert(key)
    log.notice("Live Activity art unavailable: \(key, privacy: .public)")
  }

  private static func number(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    return double.isFinite ? Int(double.rounded()) : nil
  }

  private static func rect(_ value: Any?) -> CGRect? {
    guard let raw = value as? [String: Any], let x = raw["x"] as? NSNumber,
          let y = raw["y"] as? NSNumber, let width = raw["w"] as? NSNumber,
          let height = raw["h"] as? NSNumber else { return nil }
    let rect = CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
    guard rect.width > 0, rect.height > 0 else { return nil }
    return rect
  }
}

/// What a phase looks like while the art is not staged yet.
private enum Emoji {
  static func face(packId: String?, phase: String) -> String {
    switch packId {
    case "deepy-whale": return "🐳"
    case "whale-girl": return "🐋"
    default: return byPhase(phase)
    }
  }

  private static func byPhase(_ phase: String) -> String {
    switch phase {
    case "thinking": return "🐱💭"
    case "continuedProcessing": return "🐱🛠"
    case "authorizationEnded": return "😺"
    case "waitingRecovery": return "😺"
    case "working": return "🐱🛠"
    case "waitingApproval": return "🙀"
    case "completed": return "😸"
    case "error": return "😿"
    default: return "😺"
    }
  }
}
