// 收藏目录 keep phone-side state: one list per host, absolute paths only, and a
// relative path is refused rather than stored (SFTP does not expand `~`).

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sftp_favorites_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderContainer containerFor(HostRef host) {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.listen(sftpFavoritesProvider(host), (_, _) {});
  return container;
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('adds, toggles and removes a favourite directory', () async {
    const host = HostRef.ssh('lab');
    final container = containerFor(host);
    final favorites = container.read(sftpFavoritesProvider(host).notifier);

    await favorites.add('/srv/app');
    await settle();
    expect(favorites.contains('/srv/app'), isTrue);

    await favorites.toggle('/srv/app');
    await settle();
    expect(favorites.contains('/srv/app'), isFalse);

    await favorites.toggle('/srv/app');
    await settle();
    await favorites.toggle('/srv/logs');
    await settle();
    expect(container.read(sftpFavoritesProvider(host)).paths, ['/srv/app', '/srv/logs']);

    await favorites.remove('/srv/app');
    await settle();
    expect(container.read(sftpFavoritesProvider(host)).paths, ['/srv/logs']);
  });

  test('a relative path is refused, an absolute one is not stored twice', () async {
    const host = HostRef.ssh('lab');
    final favorites = containerFor(host).read(sftpFavoritesProvider(host).notifier);

    await favorites.add('srv/app');
    await favorites.add('/srv/app');
    await favorites.add('/srv/app');
    await settle();

    expect(favorites.state.paths, ['/srv/app']);
  });

  test('each host keeps its own list', () async {
    const lab = HostRef.ssh('lab');
    const home = HostRef.ssh('home');
    final a = containerFor(lab).read(sftpFavoritesProvider(lab).notifier);
    final b = containerFor(home).read(sftpFavoritesProvider(home).notifier);

    await a.add('/srv/app');
    await b.add('/home/me');
    await settle();

    expect(a.state.paths, ['/srv/app']);
    expect(b.state.paths, ['/home/me']);
    expect(SftpFavoritesController.keyFor(lab), isNot(SftpFavoritesController.keyFor(home)));
  });

  test('favourites survive a new container for the same host', () async {
    const host = HostRef.ssh('lab');
    final first = containerFor(host).read(sftpFavoritesProvider(host).notifier);
    await first.add('/srv/app');
    await settle();

    final second = containerFor(host);
    // The load is async; the stored list arrives right after it resolves.
    await settle();
    expect(second.read(sftpFavoritesProvider(host)).paths, ['/srv/app']);
  });
}
