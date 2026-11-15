// The GitHub account a person publishes to the Creative Workshop as
// (docs/design/workshop-app.md「作者登录」). Only this file holds the token:
// it lives in memory for this run and reaches workshopAccessProvider as an
// opaque credential object, never as text a page could show. The app keeps
// no copy across starts, so every launch begins signed out.
//
//   signedOut ─startSignIn()─► awaitingCode ─approved─► signedIn
//       ▲  ◄── cancelSignIn() / expired / denied ──┘       │
//       └──────────────── signOut() / markInvalid() ◄──────┘
//
// Signing out only forgets the token in this run. Revoking the App's access
// is done on GitHub (Settings → Applications), which the page tells the person.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workshop/github_device_flow.dart';
import '../workshop/workshop_models.dart';
import 'workshop_dependencies.dart';

enum WorkshopAccountPhase { signedOut, awaitingCode, signedIn }

/// Why the last sign-in attempt ended without an account.
enum WorkshopAccountError { expired, denied, network, unconfigured }

/// Compared by identity: a new sign-in is a new account session even for the
/// same GitHub user, so nothing captured for the old token carries over.
class WorkshopAccountCredential {
  const WorkshopAccountCredential(this.token);
  final String token;
  @override
  String toString() => 'WorkshopAccountCredential(redacted)';
}

class WorkshopAccountState {
  const WorkshopAccountState({required this.phase, this.userCode, this.verificationUri,
    this.expiresAt, this.id, this.login, this.credential, this.error});
  final WorkshopAccountPhase phase;
  /// While [WorkshopAccountPhase.awaitingCode]: what to type, and where.
  final String? userCode;
  final Uri? verificationUri;
  final DateTime? expiresAt;
  /// While [WorkshopAccountPhase.signedIn].
  final int? id;
  final String? login;
  final WorkshopAccountCredential? credential;
  /// The last failed attempt; cleared when the next one starts.
  final WorkshopAccountError? error;
}

final workshopGitHubProvider = Provider<GitHubDeviceFlow>((ref) {
  final flow = GitHubDeviceFlow(ref.watch(workshopHttpFactoryProvider));
  ref.onDispose(flow.close);
  return flow;
});

/// The pause between token polls; tests make it immediate.
final workshopAccountWaitProvider = Provider<Future<void> Function(Duration)>(
  (ref) => (interval) => Future<void>.delayed(interval),
);

class WorkshopAccountController extends Notifier<WorkshopAccountState> {
  /// Bumped by every start, cancel and sign-out, so a poll that is still
  /// running for an earlier attempt can tell it no longer applies.
  int _attempt = 0;

  static const _signedOut = WorkshopAccountState(phase: WorkshopAccountPhase.signedOut);

  @override
  WorkshopAccountState build() => _signedOut;

  bool _live(int attempt) => ref.mounted && attempt == _attempt;

  /// Asks GitHub for a code, shows it (awaitingCode), then polls until the
  /// person approves it in the browser. Returns once the attempt has ended.
  Future<void> startSignIn() async {
    if (state.phase == WorkshopAccountPhase.signedIn || state.phase == WorkshopAccountPhase.awaitingCode) return;
    final attempt = ++_attempt;
    state = _signedOut;
    final github = ref.read(workshopGitHubProvider);
    final wait = ref.read(workshopAccountWaitProvider);
    try {
      final client = await ref.read(workshopClientProvider.future);
      final clientId = (await client.capabilities()).account.clientId;
      if (!_live(attempt)) return;
      if (clientId == null) workshopInvalid('workshop_account_unconfigured');
      final code = await github.requestCode(clientId);
      if (!_live(attempt)) return;
      state = WorkshopAccountState(phase: WorkshopAccountPhase.awaitingCode, userCode: code.userCode,
        verificationUri: code.verificationUri, expiresAt: DateTime.now().add(code.expiresIn));
      var interval = code.interval;
      while (true) {
        await wait(interval);
        if (!_live(attempt)) return;
        final poll = await github.pollToken(clientId, code);
        if (!_live(attempt)) return;
        switch (poll.status) {
          case GitHubPollStatus.pending:
            continue;
          case GitHubPollStatus.slowDown:
            interval += const Duration(seconds: 5);
            continue;
          case GitHubPollStatus.expired || GitHubPollStatus.denied:
            state = WorkshopAccountState(phase: WorkshopAccountPhase.signedOut,
              error: poll.status == GitHubPollStatus.expired ? WorkshopAccountError.expired : WorkshopAccountError.denied);
            return;
          case GitHubPollStatus.token:
            final token = poll.token!;
            final user = await github.user(token);
            if (!_live(attempt)) return;
            // The token exists only in this state: a cancel or sign-out that
            // arrived meanwhile bumped the attempt and this result is dropped.
            state = WorkshopAccountState(phase: WorkshopAccountPhase.signedIn, id: user.id, login: user.login,
              credential: WorkshopAccountCredential(token));
            return;
        }
      }
    } on Object catch (error) {
      if (!_live(attempt)) return;
      final code = error is WorkshopException ? error.code : null;
      state = WorkshopAccountState(phase: WorkshopAccountPhase.signedOut,
        error: code == 'workshop_account_unconfigured' || code == 'workshop_unconfigured'
            ? WorkshopAccountError.unconfigured : WorkshopAccountError.network);
    }
  }

  /// Stops waiting for approval. A code already approved on GitHub just
  /// expires unused. A sheet closing as the app shuts down may call this late.
  void cancelSignIn() {
    if (!ref.mounted || state.phase == WorkshopAccountPhase.signedIn) return;
    _attempt++;
    state = _signedOut;
  }

  /// Forgets the token in this run; a later start signs in again.
  Future<void> signOut() async {
    _attempt++;
    if (ref.mounted) state = _signedOut;
  }

  /// The Worker answered account_auth_invalid: GitHub no longer accepts this
  /// token (revoked, or the App's access removed), so ask for a new sign-in.
  Future<void> markInvalid() async {
    if (state.phase != WorkshopAccountPhase.signedIn) return;
    _attempt++;
    state = _signedOut;
  }
}

final workshopAccountProvider = NotifierProvider<WorkshopAccountController, WorkshopAccountState>(
  WorkshopAccountController.new,
);
