// Two hosts can serve a file with the same name; their scratch copies must not
// share a path, or one host's download would overwrite the other's bytes.

import 'dart:io';

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/sftp_temp_dir.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  const lab = HostRef.ssh('lab');
  const home = HostRef.ssh('home');

  setUp(() {
    root = Directory.systemTemp.createTempSync('sftp-tmp-');
    useTempRoot(root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('the same file name gets one scratch path per host', () async {
    final a = await sftpTempPath(lab, 'readme.txt');
    final b = await sftpTempPath(home, 'readme.txt');

    expect(a, isNot(b));
    expect(a, endsWith('/readme.txt'));
    expect(Directory(a).parent.path, isNot(Directory(b).parent.path));
    expect(Directory(a).parent.existsSync(), isTrue, reason: '目录按需创建');
  });

  test('two downloads on one host never share a path, even for the same name', () async {
    final first = await sftpTempPath(lab, 'a/readme.txt');
    final second = await sftpTempPath(lab, 'b/readme.txt');

    expect(first, isNot(second), reason: '/a/readme.txt 与 /b/readme.txt 并发下载不得互相覆盖');
    expect(first, endsWith('/readme.txt'), reason: '保留原文件名供预览和分享');
    expect(second, endsWith('/readme.txt'));
    expect(File(first).parent.path, isNot(File(second).parent.path));
  });

  test('a download path is created and writable', () async {
    final path = await sftpTempPath(lab, 'readme.txt');
    File(path).writeAsStringSync('bytes');
    expect(File(path).readAsStringSync(), 'bytes');
  });

  test('a remote name with separators lands on its base name', () async {
    final path = await sftpTempPath(lab, 'srv/app/notes.txt');
    expect(path, endsWith('/notes.txt'));
    expect(File(path).parent.parent.path, (await sftpTempDir(lab)).path);
  });

  test('a host id that is not path-safe cannot escape the scratch folder', () async {
    final odd = HostRef.ssh('a/../../b');
    final path = await sftpTempPath(odd, 'x.txt');
    expect(Directory(path).parent.parent.path, (await sftpTempDir(odd)).path);
    expect(path.startsWith(root.path), isTrue);
    expect(path.split('/').contains('..'), isFalse, reason: '不能出现真正的上级目录段');
  });
}
