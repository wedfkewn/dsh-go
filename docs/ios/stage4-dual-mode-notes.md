# Stage 4: local and remote modes

Implementation on `feature/ios-shellbox-dynamic-island`, based on `2c53f299`.
This is Linux-only implementation work, not evidence of an iOS build or device success.
No macOS runner was invoked. No signing, export, extension, or Android native changes.

## Reused

- Local `packages/dartssh2` 4.1.0 and `ssh_transport.dart`: password authentication, imported OpenSSH/PEM keys and passphrases, host-key verification before authentication, forwarding.
- `SshHostLink`: existing DSH managed/attach-only bootstrap, HTTP/SSE/mux client, keepalive, bounded reconnect backoff, connection status and failure reasons. No new SSH stack or wire protocol.
- Existing SSH host add/edit/remove form, remote status UI, fingerprint dialog, explicit trust reset, persisted `ActiveHostController` and host switcher.
- Existing host-specific session inventory, connection retirement, workspace preferences and remote working-directory configuration. Switching hosts clears session selection; it does not copy a workspace or session.
- `SecretStore` / `SecureSecretStore`, implemented with flutter_secure_storage (iOS Keychain, Android Keystore). Existing passwords, keys and passphrases remain separate secret entries.
- Stage 3 `ShellBoxRuntimeService` and its `dsh/shellbox` channel; native implementation and capability flag are unchanged.

## Added or changed

- Host-switcher labels explicitly identify Local and Remote. Selection continues to use the existing persisted host identity.
- Saved SSH host metadata, including host, port, username, authentication type and host-key pins, now uses SecretStore. Legacy metadata is copied to secure storage before its preferences copy is removed. Secure storage failures have a visible retry action in the switcher; writes do not publish a successful config when secure persistence fails. Credential reads and deletes propagate storage failures.
- Local Ed25519 generation uses the existing cryptography dependency's secure key generation. dartssh2 serializes the OpenSSH key. The private key stays in the form until Save writes it to secure storage; the dialog exposes only the public authorized_keys line for manual installation. No automatic key installation or SSH credential logging was added.
- First-use trust still requires the existing fingerprint dialog. Verification now also checks the pinned key algorithm when present. The link publishes its in-memory pin only after durable pinning succeeds. Changed keys remain refused with the existing hostKeyMismatch failure; reconnect never silently accepts them.
- A missing selected SSH host fails as `ssh_host_unavailable`; it no longer silently returns the local connection.
- Composer drafts now have stable host-kind/id namespaces, including the `new` slot. Switching hosts saves the outgoing draft under its captured host and replaces the visible composer. The last 30 drafts per host are retained in the new store. Legacy `chat_drafts_v1` is left untouched and is deliberately not assigned to any host: its original ownership cannot be established safely. There is no automatic migration or upload of that ambiguous content.
- An iOS RuntimeBridge adapter routes status/start/stop to Stage 3 ShellBox. Android retains its original RuntimeBridge. Inherited Android-only operations on the iOS adapter throw operation-specific errors instead of calling Android channels.
- Added regression tests for key serialization/signing, secure metadata migration, host-separated drafts and default-denied transfers. These Dart tests have NOT run here.

## Transfer safety

`remoteTransferConsentProvider` defaults to denial. The production app installs a dialog handler through its top-level ProviderScope and navigator. Approval is requested separately for each concrete operation; it is never cached or persisted.

- ChatController.send confirms the exact outgoing message and attachment names/sizes before staging files or delivering a prompt to a remote host. This includes inline images and retries. After the dialog it rechecks host/client ownership. Background callers without the app dialog cannot send remote prompts through this path.
- WorkspaceUploadRow confirms the selected batch, destination host and session before sending any bytes, then rechecks ownership. Its existing connection pin stops the remaining batch after a host switch.
- Native plugin file transport confirms each selected file before uploading it, then rechecks the captured host and provider lifetime.
- Cancelling/dismissing confirmation sends no content through these paths. Mode selection itself never transfers content. There is no new rootfs or local-session migration endpoint.

This does not claim to control arbitrary code outside these app paths (for example scripts a user independently runs on an SSH host). The existing Android WebView file chooser uses an explicit system file selection; this stage does not introduce a new iOS WebView chooser or rootfs file-export feature.

## Remaining stubs and named errors

Local execution remains unavailable: rootfs preparation, Node 24/DSH launch and real lifecycle implementation require later work and device validation.

- Stage 3: `shellbox_start_rootfs_unimplemented`, `shellbox_stop_unimplemented`, `shellbox_restart_unimplemented`; malformed status still throws `shellbox_status_invalid_response`.
- Adapter: `shellbox_install_rootfs_unimplemented`, `shellbox_reset_unimplemented`, `shellbox_logs_unimplemented`, `shellbox_log_snapshot_unimplemented`.
- Inherited runtime operations fail as `shellbox_<method>_unimplemented` (for example `shellbox_installManagedSkill_unimplemented`, `shellbox_storageStatus_unimplemented`, `shellbox_lastKnownGood_unimplemented`). They do not claim to complete an operation.
- Secure metadata migration/write failure cannot authorize a host pin. The migration removal error is `ssh_host_metadata_migration_failed`; attempted saves while storage loading has failed use `ssh_host_storage_unavailable`.
- Rejected native file transfer uses `remote_transfer_not_confirmed` internally and follows the existing failed/cancelled selection cleanup.

`RuntimePlatformCapabilities.shellBoxRuntime` remains false. Status reports the native unimplemented reason as a runtime error, never a running server or fake endpoint.

## Validation and limitations

Executed on Linux:

- `git diff --check`: passed.
- `python3 app/tool/l10n_merge.py --check`: passed (71 parts, 7328 keys).
- `python3 app/tool/guide_sync.py --check`: passed (26 files).
- `node sdk/plugin-kit/scripts/sync-skill.mjs --check`: passed.
- `python3 -m unittest discover -s app/tool -p 'test_l10n*.py'`: 56 passed.
- `python3 -m unittest discover -s app/tool -p 'test_guide_sync.py'`: 16 passed.
- Full app/tool Python discovery: 76 reported tests, one import error because numpy is absent; not a full pass.
- `node --test runtime/tests/*.test.mjs`: failed (30 pass / 142 fail). Repeated with `TMPDIR=/tmp NODE_OPTIONS=` to remove the unwritable default temp directory and machine browser preload: 41 pass / 131 fail. The runtime suite requires prepared DSH_PREFIX/PNPM_PREFIX inputs (see CI); they are not configured here. No runtime source was changed.
- `npm test --prefix sdk/plugin-kit`: failed; initial run reports 9 pass / 7 fail, including EROFS under the default /data/tmp. Retried with writable /tmp and without NODE_OPTIONS; the run did not produce a complete successful summary. A direct check-config test reports 3 pass / 3 fail, including empty CLI JSON output. No SDK source was changed.
- Android tracked-file diff: empty. New/changed source reviewed for credential literals; no real key, password or token values added. No codex logs are included.

`python3 app/tool/l10n_merge.py` merged the bilingual ARB inputs but could not invoke Flutter. Generated Dart localization classes are therefore pending `flutter gen-l10n`; they were NOT edited by hand. Run generation before analysis/tests: the new getters are not present in the checked-in generated classes yet.

NOT RUN: Dart formatting/analyzer, Flutter tests (including new regression tests), Flutter/iOS build, Xcode, SSH integration against a real DSH host, Keychain persistence on iOS, or real-device lifecycle tests. There is no Flutter/Dart/Xcode toolchain here. No iOS build claim is made.

Git status confirmed the requested branch/HEAD and clean starting tree. Fetch failed writing .git/FETCH_HEAD due to this session's sandbox restriction; a subsequent git status succeeded. Source changes stay in this repository for the coordinator if Git metadata writes remain blocked.

## Future macOS and device checks

1. Run Flutter dependency resolution, `flutter gen-l10n`, `dart format` on changed Dart files, `flutter analyze`, and relevant remote/draft/native-file/runtime widget tests. Existing tests that intentionally send remote messages must install an explicit test consent handler; default denial is intentional. Review existing host-persistence fixtures for secure-store migration expectations.
2. Build with `flutter build ios --no-codesign` on macOS/Xcode. No signing or IPA export is required for that check.
3. On device, prove Keychain metadata/pins/password/private-key persistence, storage-error retry and host removal. Generate a key, manually install its public half, authenticate, then restart the app and authenticate again. Test password and encrypted imported keys too.
4. Prove first-connect rejection/approval, matching pin after restart, changed-key refusal before credential authentication and no automatic pin reset. Test network loss, reconnect backoff, exhausted retries and visible failure reasons.
5. Populate separate local and remote session/workspace/draft state (including duplicate session IDs and `new` drafts). Switch repeatedly and restart; verify no old host rows, paths, quote/attachment content or writes appear on the other host. Preserve the legacy draft store for a future explicit recovery UI.
6. Capture remote traffic while approving, cancelling and switching hosts during chat/attachment/workspace/plugin-file confirmations. Cancellation and retired ownership must send no selected content. No local files, sessions or rootfs should move simply because Remote was selected.
7. Local mode must reach the Stage 3 named failures. Actual ShellBox rootfs/Node 24/DSH execution, logs, lifecycle and background behavior remain unproven until implemented and tested on a real iOS device.

## Final Git state and changed files

The explicit-path `git add` attempt failed creating `.git/index.lock` with
`Read-only file system`. No commit or push was made. HEAD remains `2c53f299`;
the coordinator must create the single Stage 4 commit. No scratch clone or
worktree was used. No Actions run was triggered manually.

- `app/lib/app.dart`
- `app/lib/l10n/app_en.arb`
- `app/lib/l10n/app_zh.arb`
- `app/lib/l10n/parts/remote_en.arb`
- `app/lib/l10n/parts/remote_zh.arb`
- `app/lib/main.dart`
- `app/lib/plugins/native/native_files.dart`
- `app/lib/remote/secret_store.dart`
- `app/lib/remote/ssh/key_generation.dart`
- `app/lib/remote/ssh/ssh_host_config.dart`
- `app/lib/remote/ssh/ssh_link.dart`
- `app/lib/remote/transfer_consent.dart`
- `app/lib/runtime/runtime_state.dart`
- `app/lib/runtime/shellbox/shellbox_runtime_bridge.dart`
- `app/lib/state/chat_state.dart`
- `app/lib/state/connection_state.dart`
- `app/lib/state/draft_store.dart`
- `app/lib/state/hosts_state.dart`
- `app/lib/ui/chat/chat_screen.dart`
- `app/lib/ui/remote/host_switcher.dart`
- `app/lib/ui/remote/ssh_host_form.dart`
- `app/lib/ui/remote/transfer_consent_dialog.dart`
- `app/lib/ui/session/workspace_upload.dart`
- `app/test/remote/stage4_dual_mode_test.dart`
- `app/test/runtime/shellbox_runtime_service_test.dart`
- `docs/ios/stage4-dual-mode-notes.md`
