# Stage 2: iOS project

Source: local Flutter 3.47.7 templates in `packages/flutter_tools/templates/app/ios.tmpl`, plus `cocoapods/Podfile-ios`, from the supplied Flutter checkout (Flutter BSD-3-Clause license). No network retrieval. CocoaPods rendering: Swift Package Manager and platform-channel plugin example sections disabled; development-team section omitted.

Bundle ID: **io.github.ccch1mneyyy.dshApp** (Android application ID `io.github.ccch1mneyyy.dsh_app`, project component converted to lowerCamelCase for iOS). RunnerTests: `io.github.ccch1mneyyy.dshApp.RunnerTests`. Display name: `Dsh App`; project name: `dsh_app`. Version `1.0.15+1` stays in pubspec.yaml; Flutter generates FLUTTER_BUILD_NAME/NUMBER. No Generated.xcconfig or plugin registrant is handwritten.

Deployment target: **15.0**, retained from template; no verified plugin requirement to raise it. Swift: **5.0**. Signing: Automatic (explicit CODE_SIGN_STYLE added to Runner configurations), no DEVELOPMENT_TEAM; no signing assets. Use `flutter build ios --no-codesign`. The template's AppFrameworkInfo.plist minimum is retained verbatim.

Rendering exception: app template `.img.tmpl` files are zero-byte markers for the external flutter_template_images package, which is not supplied. Instead of shipping empty PNGs, the matching PNG filenames are copied from the same checkout's official `module/ios/host_app_ephemeral/Runner.tmpl/Assets.xcassets/` templates. They are valid Flutter template images, but byte identity with the external app image package is NOT verified. All text templates render completely; trailing whitespace from disabled Mustache sections is removed. The Flutter BSD license is retained in `app/ios/FLUTTER_TEMPLATE_LICENSE`.

Morning Actions must prove CocoaPods integration, generated plugin registration, project/scheme validity, asset compilation, plugin deployment compatibility, Xcode 26.0.1 compilation and unsigned linking. None is verified on this Linux server. Device launch remains unverified.

## Stage separation

Before Stage 3 edits, the complete Stage 2 `app/ios` tree was saved to `/tmp/dsh-ios-stage2.tar`. Restore that tree for commit 1; restore the final working tree for commit 2. Stage 3 changes shared template files; committing the entire final app/ios tree as Stage 2 would mix the stages. No git writes were performed.

## Files created in Stage 2

- `app/ios/.gitignore`
- `app/ios/Flutter/AppFrameworkInfo.plist`
- `app/ios/Flutter/Debug.xcconfig`
- `app/ios/Flutter/Release.xcconfig`
- `app/ios/Podfile`
- `app/ios/Runner/AppDelegate.swift`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png`
- `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png`
- `app/ios/Runner/Assets.xcassets/LaunchImage.imageset/Contents.json`
- `app/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png`
- `app/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png`
- `app/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png`
- `app/ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md`
- `app/ios/Runner/Base.lproj/LaunchScreen.storyboard`
- `app/ios/Runner/Base.lproj/Main.storyboard`
- `app/ios/Runner/Info.plist`
- `app/ios/Runner/Runner-Bridging-Header.h`
- `app/ios/Runner/SceneDelegate.swift`
- `app/ios/Runner.xcodeproj/project.pbxproj`
- `app/ios/Runner.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `app/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist`
- `app/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings`
- `app/ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme`
- `app/ios/Runner.xcworkspace/contents.xcworkspacedata`
- `app/ios/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist`
- `app/ios/Runner.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings`
- `app/ios/RunnerTests/RunnerTests.swift`
- `docs/ios/stage2-ios-project-notes.md`
- `app/ios/FLUTTER_TEMPLATE_LICENSE`
