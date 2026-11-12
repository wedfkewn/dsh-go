# ShellBox channel contract

Dart uses MethodChannel `dsh/shellbox`; it never falls back to `dsh/runtime`.
Native currently implements only `status`, `start`, `stop`, and `restart` stubs.
Missing handlers become `shellbox_<method>_unimplemented` PlatformExceptions in
the bridge; native errors propagate unchanged. Completion must reflect native
results, including failures, rather than directory creation or local assumptions.

| Method | Arguments | Success response |
| --- | --- | --- |
| `status` | none | RuntimeStatus map described below |
| `start` | `{env: Map<String,String>, phoneStorage: bool, mode: String?, visualReplies: bool}` | null |
| `stop`, `restart` | none | null |
| `install` | none, or `{dropKept: true}` | null after installation completes |
| `reset` | `{keep: List<String>}` | null after reset completes |
| `logs` | `{lines: int}` (Dart default 500) | `List<String>` |
| `logSnapshot` | `{lines: int}` (Dart default 300) | `{entries: List<LogEntry>, throughSeq: int}` |

`keep` contains zero or more of `uiAndSkills` and `pluginsAndSettings`, using
`ResetKeep.wire`. A LogEntry is `{seq: int, line: String, stream: String}` with
stream `stdout`, `stderr`, or `system`. Lines must be redacted natively. Sequence
numbers increase for the native process lifetime, including across runtime
restarts/resets. `throughSeq` is the highest received sequence at the snapshot's
capture time, including when entries are empty.

Status requires `phase`: `notInstalled`, `installing`, `installed`, `starting`,
`running`, `stopping`, or `error`. The legacy `unimplemented` maps to UI error.
Optional fields follow `RuntimeStatus.fromMap`: `abi`, `bundledVersion`,
`installedVersion`, `dshVersion`, `nodeVersion`, `baseUrl`, `token`,
`managedSkillGeneration`, `mode`, `workspaceRecovery`, `safeState`, `safeReason`,
`strikes`, `autoSafe`, `failure`, `mainFailure`, `healthyAt`, and the remaining
optional diagnostics in that parser. Errors may be a string or
`{code: String, message: String}`. Omitted optional fields use parser defaults;
readiness requires running plus baseUrl and token.

The bridge polls immediately on subscription, then one second after each reply.
This keeps lifecycle changes visible without high idle channel traffic. Polling
stops with the last listener and resumes with a fresh status on resubscription.
Errors are emitted as stream errors; subsequent scheduled polls may recover.
Optional `notices: List<String>` in status is drained by native per call and
emitted as RuntimeNoticeEvents. There is no native EventChannel requirement yet.

Portable inherited operations retain the base bridge's argument and response
shapes: `installManagedSkill`, `cancelManagedSkill`, `lastKnownGood`,
`restoreLastKnownGood`, `safePreflight`, `moveAside`, `clearFailure`, `setAutoSafe`,
`setWorkspaceRecovery`, `failureLog`, and `networkMetered`. These need native
handlers before use. Android-only methods explicitly fail by operation name:
`setDirectEngine`, `setTawcEngine`, `storageStatus`, `requestStorage`,
`openAllFilesAccess`, `batteryExempt`, `requestBatteryExempt`,
`backgroundSettings`, `openBackgroundSettings`, and `openVendorSettings`.

Native follow-up must implement installation, reset, log retrieval/snapshots and
real lifecycle/status responses, then portable operations used by the iOS UI.
Device validation is still required after that implementation.
