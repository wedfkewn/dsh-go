import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dartssh2/dartssh2.dart';

/// Generates locally using the cryptography package's secure random source.
/// Only the public half is intended for installation on a remote host.
Future<SSHKeyPair> generateSshKey() async {
  final generated = await Ed25519().newKeyPair();
  final seed = await generated.extractPrivateKeyBytes();
  final public = await generated.extractPublicKey();
  return OpenSSHEd25519KeyPair(
    Uint8List.fromList(public.bytes),
    Uint8List.fromList([...seed, ...public.bytes]),
    'dsh-Go',
  );
}

String sshAuthorizedKey(SSHKeyPair key) => '${key.name} ${base64Encode(key.toPublicKey().encode())} dsh-Go';
