// The launch screen's fixed colours live in Dart (`LaunchColors`). The iOS launch screen is a
// system-background image with no app colour of its own, so there is no native table left to
// drift from; what still has to hold is that the hand-over uses the default palette, or the
// overlay would show a colour step.
//
// (The Android build had res/values{,-night}/colors.xml to compare against. That host is not
// part of this source tree, so those two comparisons went with it.)

import 'package:dsh_app/launch/custom_launch.dart';
import 'package:dsh_app/ui/theme/palette.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the wordmark ink is the default palette text, and the page is the default backdrop', () {
    expect(LaunchColors.ink, DshPalette.ink);
    expect(LaunchColors.paper, DshPalette.paper);
    expect(LaunchColors.mistTop, DshPalette.mistTop);
    expect(LaunchColors.nightTop, DshPalette.nightTop);
  });
}
