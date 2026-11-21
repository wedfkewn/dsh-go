// The file/terminal failure words are UI, so they are covered here rather than
// in the state layer: every failure kind has its own sentence in both
// languages, and a server that refuses a pty is not reported as a lost
// connection or as a generic failure.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/sftp_state.dart';
import 'package:dsh_app/state/ssh_terminal_state.dart';
import 'package:dsh_app/ui/remote/sftp_failure_text.dart';
import 'package:dsh_app/ui/remote/ssh_terminal_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final zh = lookupL10n(AppLocale.zhCN);
  final en = lookupL10n(AppLocale.en);

  test('every SFTP failure kind has words in both languages', () {
    for (final kind in SftpFailureKind.values) {
      final failure = SftpFailure(kind);
      final zhText = sftpFailureText(zh, failure);
      final enText = sftpFailureText(en, failure);
      expect(zhText.trim(), isNotEmpty, reason: '$kind 缺中文文案');
      expect(enText.trim(), isNotEmpty, reason: '$kind 缺英文文案');
      if (kind != SftpFailureKind.other) {
        expect(zhText, isNot(enText), reason: '$kind 中英文不得相同');
      }
    }
  });

  test('a disconnected host reads as disconnected, not as a generic failure', () {
    expect(sftpFailureText(zh, const SftpFailure(SftpFailureKind.connectionLost)), '连接已断开，请重试');
    expect(sftpFailureText(zh, const SftpFailure(SftpFailureKind.notConnected)), '连接已断开，请重试');
  });

  test('a server that refuses the pty says so, and is not a lost connection', () {
    final refused = sshFailureText(zh, const SshFailure(SshFailureKind.ptyRefused));
    final lost = sshFailureText(zh, const SshFailure(SshFailureKind.connectionLost));
    final generic = sshFailureText(zh, const SshFailure(SshFailureKind.other));

    expect(refused, '服务器拒绝分配终端（PTY）');
    expect(refused, isNot(lost));
    expect(refused, isNot(generic));
    expect(sshFailureText(en, const SshFailure(SshFailureKind.ptyRefused)), 'The server refused a terminal (PTY)');
  });

  test('every terminal failure kind has words in both languages', () {
    for (final kind in SshFailureKind.values) {
      expect(sshFailureText(zh, SshFailure(kind)).trim(), isNotEmpty, reason: '$kind 缺中文文案');
      expect(sshFailureText(en, SshFailure(kind)).trim(), isNotEmpty, reason: '$kind 缺英文文案');
    }
  });
}
