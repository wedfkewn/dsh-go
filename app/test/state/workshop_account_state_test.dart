import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart';
import 'workshop_auth_test_support.dart' show AuthClient;

/// The real controller over a scripted GitHub and a pause between polls that
/// the test releases (or skips).
class _World {
  _World({String? clientId = 'Iv1.test', this.manualWait = false}) {
    client.value = WorkshopCapabilities.fromJson(workshopCaps(clientId: clientId));
    container = ProviderContainer(overrides: [
      workshopHttpFactoryProvider.overrideWithValue((_) => http),
      workshopClientProvider.overrideWith((ref) async => client),
      workshopAccountWaitProvider.overrideWithValue((interval) {
        waits.add(interval);
        if (!manualWait) return Future<void>.value();
        release = Completer<void>();
        return release!.future;
      }),
    ]);
  }
  final client = AuthClient();
  final bool manualWait;
  final waits = <Duration>[];
  Completer<void>? release;
  late final ProviderContainer container;
  /// GitHub's answers, in order, keyed by path.
  final answers = <String, List<Object?>>{};
  late final http = FakeWorkshopHttp((method, url, headers, body) {
    final next = answers[url.path]!.removeAt(0);
    if (next is Exception) throw next;
    return workshopJsonResponse(next);
  });

  WorkshopAccountController get controller => container.read(workshopAccountProvider.notifier);
  WorkshopAccountState get state => container.read(workshopAccountProvider);
}

Map<String, Object?> _code() => {'device_code': 'device_secret_0123', 'user_code': 'WDJB-MJHT',
  'verification_uri': 'https://github.com/login/device', 'expires_in': 900, 'interval': 5};

void main() {
  test('every run starts signed out: the token is never restored from storage', () {
    final world = _World();
    final other = ProviderContainer();
    addTearDown(world.container.dispose);
    addTearDown(other.dispose);
    expect(world.state.phase, WorkshopAccountPhase.signedOut);
    expect(world.state.credential, isNull);
    expect(other.read(workshopAccountProvider).phase, WorkshopAccountPhase.signedOut);
  });

  test('signs in: shows the code, slows down when asked, then keeps the account in memory', () async {
    final world = _World();
    addTearDown(world.container.dispose);
    world.answers['/login/device/code'] = [_code()];
    world.answers['/login/oauth/access_token'] = [
      {'error': 'authorization_pending'}, {'error': 'slow_down'},
      {'access_token': 'gho_new_token', 'token_type': 'bearer', 'scope': ''},
    ];
    world.answers['/user'] = [{'id': 583231, 'login': 'octo-cat'}];
    final seen = <WorkshopAccountState>[];
    world.container.listen(workshopAccountProvider, (_, next) => seen.add(next));
    await world.controller.startSignIn();
    final waiting = seen.firstWhere((s) => s.phase == WorkshopAccountPhase.awaitingCode);
    expect((waiting.userCode, waiting.verificationUri.toString()), ('WDJB-MJHT', 'https://github.com/login/device'));
    expect(waiting.expiresAt, isNotNull);
    expect(world.waits, [const Duration(seconds: 5), const Duration(seconds: 5), const Duration(seconds: 10)]);
    expect((world.state.phase, world.state.id, world.state.login, world.state.error),
      (WorkshopAccountPhase.signedIn, 583231, 'octo-cat', null));
    expect(world.state.credential!.token, 'gho_new_token');
    expect(world.state.credential.toString(), isNot(contains('gho_')));
  });

  for (final (answer, error) in [('expired_token', WorkshopAccountError.expired), ('access_denied', WorkshopAccountError.denied)]) {
    test('$answer ends signed out with ${error.name}', () async {
      final world = _World();
      addTearDown(world.container.dispose);
      world.answers['/login/device/code'] = [_code()];
      world.answers['/login/oauth/access_token'] = [{'error': answer}];
      await world.controller.startSignIn();
      expect((world.state.phase, world.state.error), (WorkshopAccountPhase.signedOut, error));
    });
  }

  test('no client id means unconfigured, and GitHub is never asked', () async {
    final world = _World(clientId: null);
    addTearDown(world.container.dispose);
    await world.controller.startSignIn();
    expect(world.state.error, WorkshopAccountError.unconfigured);
    expect(world.http.requests, isEmpty);
  });

  test('a transport failure reads as network', () async {
    final world = _World();
    addTearDown(world.container.dispose);
    world.answers['/login/device/code'] = [const SocketException('offline')];
    await world.controller.startSignIn();
    expect((world.state.phase, world.state.error), (WorkshopAccountPhase.signedOut, WorkshopAccountError.network));
  });

  test('cancelling stops the poll; a later approval is never collected', () async {
    final world = _World(manualWait: true);
    addTearDown(world.container.dispose);
    world.answers['/login/device/code'] = [_code()];
    world.answers['/login/oauth/access_token'] = [{'access_token': 'gho_late', 'token_type': 'bearer'}];
    final signingIn = world.controller.startSignIn();
    await pumpEventQueue();
    expect(world.state.phase, WorkshopAccountPhase.awaitingCode);
    world.controller.cancelSignIn();
    expect(world.state.phase, WorkshopAccountPhase.signedOut);
    world.release!.complete();
    await signingIn;
    expect((world.state.phase, world.state.credential), (WorkshopAccountPhase.signedOut, null));
    expect(world.http.requests.map((r) => r.url.path), ['/login/device/code']);
  });

  test('a token approval that lands after cancel is dropped', () async {
    final world = _World(manualWait: true);
    addTearDown(world.container.dispose);
    world.answers['/login/device/code'] = [_code()];
    world.answers['/login/oauth/access_token'] = [{'access_token': 'gho_late', 'token_type': 'bearer', 'scope': ''}];
    world.answers['/user'] = [{'id': 1, 'login': 'late'}];
    final done = world.controller.startSignIn();
    await pumpEventQueue();
    world.controller.cancelSignIn();
    world.release!.complete();
    await done;
    expect((world.state.phase, world.state.credential), (WorkshopAccountPhase.signedOut, null));
  });

  test('signing out and a refused token both forget the in-memory account', () async {
    for (final forget in [(WorkshopAccountController c) => c.signOut(), (WorkshopAccountController c) => c.markInvalid()]) {
      final world = _World();
      addTearDown(world.container.dispose);
      world.answers['/login/device/code'] = [_code()];
      world.answers['/login/oauth/access_token'] = [{'access_token': 'gho_saved', 'token_type': 'bearer', 'scope': ''}];
      world.answers['/user'] = [{'id': 7, 'login': 'octo'}];
      await world.controller.startSignIn();
      expect(world.state.phase, WorkshopAccountPhase.signedIn);
      await forget(world.controller);
      expect((world.state.phase, world.state.credential), (WorkshopAccountPhase.signedOut, null));
    }
  });
}
