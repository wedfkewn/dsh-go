# iOS onboarding when local installation is unavailable

Fresh installs still show welcome, then the existing 本机 / 远程主机 choice
(`runtimeStepAsks` in `root_gate.dart`). Nothing is auto-installed while that
choice is visible. On iOS, choosing 本机 now installs on `RuntimeSetupPage`
instead of entering the appearance/access/account steps beside an unpack.
Android retains that parallel setup path.

`RuntimeInstallController` preserves `PlatformException.code ==
'shellbox_install_unimplemented'` as `RuntimeInstallFailure.unavailable` on iOS.
`localInstallUnavailableProvider` also recognizes the same exact code in
`RuntimeStatus.error`, either alone or followed by `:` and the native message
(the bridge's map-to-string format). This covers both the thrown result before
polling and a subsequent native status. Other codes and Android failures do not
trigger this path. The flag is cleared when a new install request starts; native
status remains authoritative, and no installed version or ready state is forged.

The failed runtime page and setup status sheet replace Retry with a primary
filled 改用远程主机 button. Logs remain available. The title reuses translated
安装本机运行环境 + 不可用, with the existing remote-host explanation beneath it;
no ARB or generated localization changes are needed. Reopening a page with known
unavailability does not automatically install again. Other failures retain Retry.

The existing `RootGate._useRemote` opens `RemoteScreen`. Selecting an actual
remote host clears any saved parallel setup step, persists `localDeclined = true`
and enters home without starting a local engine. On relaunch,
`initialOnboardingStep` returns home for the missing runtime and saved decline.
Cancelling the host picker without selecting a remote returns to the choice or
failure page; merely opening the picker does not claim a connection exists.

## Cloud Mac verification (not run on this Linux machine)

1. Run `flutter analyze` in `app`, then build/run the app on the iPhone 17
   simulator using the existing Mac setup. No signing or workflow change is needed.
2. Delete the app from the simulator and install afresh to clear onboarding prefs.
   Tap 开始. Confirm the 本机 / 远程主机 choice appears before installation.
3. Select 本机 and continue. Confirm it stays on the runtime page, reports local
   installation unavailable, shows a prominent filled 改用远程主机 button and
   查看日志, and shows **no 重试**. It must not advance into appearance/account
   setup or display installed/ready. Logs should show the real named native error.
4. Tap 改用远程主机. Cancel once: confirm the failure page remains usable with
   the primary remote action and no Retry. Open it again and select a configured,
   reachable test remote host. Confirm home opens and uses that remote host.
   Terminate/relaunch: confirm home remains reachable without a local install.
5. Delete/reinstall again. Choose 远程主机 directly, select the test host and
   confirm home opens without attempting a local install.
6. For a resumed older onboarding session at finishing, open the setup status
   sheet after the named install failure: confirm remote is primary and Retry is
   absent there too. Selecting a remote must clear the saved setup step.
7. With a test bridge returning a different install PlatformException (for example
   `install_failed`), confirm Retry remains available on iOS. On an Android test
   device/emulator, confirm 本机 still enters parallel setup, attempts installation,
   and a transient install failure offers Retry. Never change the production
   native handler to simulate successful installation.

Local checks: `python3 app/tool/l10n_merge.py --check` and `git diff --check`.
Compilation, Flutter tests and simulator checks are unverified: this machine has
no Flutter/Dart SDK, Xcode/macOS or iOS simulator. Fetching origin main failed
because `.git/FETCH_HEAD` is read-only; work stays on the supplied branch/HEAD.
No commit, push or Actions run was performed.
