// The tunnel's phone side must be reachable on 127.0.0.1 only: the remote
// DSH token travels through this socket, so a LAN-reachable listener would let
// another device on the network use it. Guards LocalForwarder.bind.

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/remote/ssh/local_forward.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_ssh.dart';

void main() {
  test('the forwarder accepts loopback connections and pipes bytes back', () async {
    final forwarder = await LocalForwarder.bind(() async => FakeChannel(echo: true));
    addTearDown(forwarder.close);
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, forwarder.port);
    addTearDown(() => socket.destroy());
    final received = <int>[];
    final done = Completer<void>();
    socket.listen((data) {
      received.addAll(data);
      if (received.length >= 4 && !done.isCompleted) done.complete();
    });
    socket.add([1, 2, 3, 4]);
    await socket.flush();
    await done.future.timeout(const Duration(seconds: 5));
    expect(received, [1, 2, 3, 4]);
    expect(forwarder.activeConnections, 1);
  });

  test('the forwarder is not reachable from a non-loopback address', () async {
    final forwarder = await LocalForwarder.bind(() async => FakeChannel(echo: true));
    addTearDown(forwarder.close);
    final external = await _nonLoopbackV4();
    if (external == null) {
      markTestSkipped('no non-loopback IPv4 interface');
      return;
    }
    await expectLater(
      Socket.connect(external, forwarder.port, timeout: const Duration(seconds: 2)),
      throwsA(anyOf(isA<SocketException>(), isA<TimeoutException>())),
    );
  });
}

Future<InternetAddress?> _nonLoopbackV4() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!address.isLoopback) return address;
    }
  }
  return null;
}
