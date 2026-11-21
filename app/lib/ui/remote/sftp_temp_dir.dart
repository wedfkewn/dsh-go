// Local scratch paths for SSH file transfers, one folder per host. Two hosts
// can serve the same file name (`/readme.txt`), so a shared cache directory
// would let one host's download overwrite the other's — and an attachment read
// afterwards would carry the wrong server's bytes.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../state/hosts_state.dart';

/// `<cache>/sftp/<kind>-<id>/`, created on demand.
Future<Directory> sftpTempDir(HostRef host) async {
  final root = await getTemporaryDirectory();
  final id = host.id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final dir = Directory('${root.path}/sftp/${host.kind.name}-$id');
  await dir.create(recursive: true);
  return dir;
}

/// A fresh local path for one download of [name] on [host]. Every download gets
/// its own folder, so `/a/readme.txt` and `/b/readme.txt` can be in flight at
/// the same time without either overwriting the other; the file keeps its own
/// name inside, which is what previews and the share sheet show.
Future<String> sftpTempPath(HostRef host, String name) async {
  final dir = await sftpTempDir(host);
  final target = Directory('${dir.path}/${_nextFolder()}');
  await target.create(recursive: true);
  return '${target.path}/${name.split('/').last}';
}

var _seq = 0;

/// Unique per call even within the same microsecond.
String _nextFolder() => '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';
