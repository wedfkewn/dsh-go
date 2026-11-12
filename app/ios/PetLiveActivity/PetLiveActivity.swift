import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PetLiveActivityBundle: WidgetBundle {
  var body: some Widget { PetLiveActivity() }
}

struct PetLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: PetActivityAttributes.self) { context in
      HStack(spacing: 12) {
        PetExpression(phase: context.state.phase, label: context.isStale ? context.state.staleLabel : context.state.label)
          .font(.system(size: 32))
        Text(context.isStale ? context.state.staleLabel : context.state.label).font(.headline)
        Spacer()
        Image(systemName: context.isStale ? "clock.badge.exclamationmark" : appearance(context.state.phase).symbol)
      }
      .padding()
      .foregroundStyle(appearance(context.state.phase).color)
      .activityBackgroundTint(Color.black.opacity(0.9))
      .activitySystemActionForegroundColor(.white)
      .widgetURL(context.attributes.url)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          PetExpression(phase: context.state.phase, label: context.isStale ? context.state.staleLabel : context.state.label).font(.system(size: 30))
        }
        DynamicIslandExpandedRegion(.trailing) {
          Image(systemName: context.isStale ? "clock.badge.exclamationmark" : appearance(context.state.phase).symbol)
            .foregroundStyle(appearance(context.state.phase).color)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.isStale ? context.state.staleLabel : context.state.label).font(.headline).lineLimit(2)
            .foregroundStyle(appearance(context.state.phase).color)
        }
      } compactLeading: {
        PetExpression(phase: context.state.phase, label: context.isStale ? context.state.staleLabel : context.state.label)
      } compactTrailing: {
        Image(systemName: context.isStale ? "clock.badge.exclamationmark" : appearance(context.state.phase).symbol)
          .foregroundStyle(appearance(context.state.phase).color)
          .accessibilityLabel(context.isStale ? context.state.staleLabel : context.state.label)
      } minimal: {
        PetExpression(phase: context.state.phase, label: context.isStale ? context.state.staleLabel : context.state.label)
      }
      .widgetURL(context.attributes.url)
      .keylineTint(appearance(context.state.phase).color)
    }
  }
}

// System emoji expressions: no repackaging of Deepy/鲸娘 art. Static by design;
// WidgetKit owns rendering cadence, not the Flutter sprite timer.
private func appearance(_ phase: String) -> (face: String, symbol: String, color: Color) {
  switch phase {
  case "thinking": return ("🐱💭", "ellipsis", .cyan)
  case "working": return ("🐱🛠", "gearshape.fill", .orange)
  case "waitingApproval": return ("🙀", "hand.raised.fill", .yellow)
  case "completed": return ("😸", "checkmark.circle.fill", .green)
  case "error": return ("😿", "exclamationmark.triangle.fill", .red)
  default: return ("😺", "moon.fill", .mint)
  }
}

private struct PetExpression: View {
  let phase: String
  let label: String
  var body: some View {
    Text(appearance(phase).face)
      .minimumScaleFactor(0.5)
      .lineLimit(1)
      .accessibilityLabel(label)
  }
}
