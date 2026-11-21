// Instance discovery against a real `node ... web` process: the scan must
// report only listening TCP ports (never the process id) and must treat
// ownership conservatively — a managed instance needs this app's recorded pid
// *and* the matching start time before its old token is returned.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/ssh/dsh_discovery.dart';
import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory home;
  late Process fakeDsh;
  late int listenPort;

  Directory state() => Directory('${home.path}/.dsh-app-remote');

  Future<List<RemoteDshInstance>> scan() async {
    final result = await LocalProcessShell(
      environment: {'HOME': home.path, 'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
    ).run(discoveryScript(), timeout: const Duration(seconds: 20));
    expect(result.exitCode, 0, reason: result.stderr);
    return parseDshInstances(result.stdout);
  }

  RemoteDshInstance ours(List<RemoteDshInstance> instances) =>
      instances.singleWhere((instance) => instance.pid == fakeDsh.pid);

  setUp(() async {
    home = Directory.systemTemp.createTempSync('dsh-discovery-');
    state().createSync();
    fakeDsh = await Process.start('node', [
      '-e',
      'require("http").createServer((q,s)=>s.end("ok")).listen(0,"127.0.0.1",function(){console.log(this.address().port)})',
      'web',
    ]);
    listenPort = await fakeDsh.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(int.parse)
        .first
        .timeout(const Duration(seconds: 10));
    File('${state().path}/web.log').writeAsStringSync('dsh web: http://127.0.0.1:$listenPort/?token=old-token\n');
  });

  tearDown(() async {
    fakeDsh.kill();
    await fakeDsh.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    home.deleteSync(recursive: true);
  });

  test('the reported ports are listening ports, never the process id', () async {
    final found = ours(await scan());
    expect(found.ports, [listenPort]);
    expect(found.ports, isNot(contains(fakeDsh.pid)));
  });

  test('without web.st the instance is not managed and gets no token', () async {
    File('${state().path}/web.pid').writeAsStringSync('${fakeDsh.pid}');
    final found = ours(await scan());
    expect(found.managed, isFalse);
    expect(found.token, isNull);
  });

  test('a mismatched start time is not managed and gets no token', () async {
    File('${state().path}/web.pid').writeAsStringSync('${fakeDsh.pid}');
    File('${state().path}/web.st').writeAsStringSync('0');
    final found = ours(await scan());
    expect(found.managed, isFalse);
    expect(found.token, isNull);
  });

  test('pid plus matching start time is managed and carries this app token', () async {
    File('${state().path}/web.pid').writeAsStringSync('${fakeDsh.pid}');
    File('${state().path}/web.st').writeAsStringSync(_startTime(fakeDsh.pid));
    final found = ours(await scan());
    expect(found.managed, isTrue);
    expect(found.token, 'old-token');
  });
}

/// Field 22 of /proc/PID/stat, after the comm in parentheses, the same way
/// the discovery script reads it.
String _startTime(int pid) {
  final stat = File('/proc/$pid/stat').readAsStringSync();
  final close = stat.lastIndexOf(') ');
  final fields = stat.substring(close + 2).split(' ');
  return fields[19];
}
