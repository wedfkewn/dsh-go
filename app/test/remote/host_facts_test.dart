// 主机信息 is read-only facts parsed from one script's output: Linux and macOS
// answer in different units and occasionally not at all, so the parser must
// never invent a number, and a big machine must not be read as the small unit.

import 'package:dsh_app/remote/ssh/host_facts.dart';
import 'package:flutter_test/flutter_test.dart';

const _linux = '''
os=Linux
kernel=6.8.0-45-generic
arch=x86_64
host=lab
cpus=8
mem_kb=16384000
load=0.15 0.10 0.05 1/234 5678
uptime=12345.67
disk=overlay 102400 51200 51200 50% /
''';

const _mac = '''
os=Darwin
kernel=24.1.0
arch=arm64
host=MacBook
cpus=10
mem_bytes=17179869184
load={ 1.23 4.56 7.89 }
disk=/dev/disk3s1 488245288 209715200 269000000 44% /System/Volumes/Data
''';

void main() {
  test('a Linux host reports its own units', () {
    final facts = HostFacts.parse(_linux);
    expect(facts.any, isTrue);
    expect(facts.os, 'Linux');
    expect(facts.cpus, 8);
    expect(facts.memoryBytes, 16384000 * 1024, reason: 'MemTotal 是 kB');
    expect(facts.uptime, const Duration(seconds: 12346));
    expect(facts.load, '0.15 · 0.10 · 0.05');
    expect(facts.diskTotalBytes, 102400 * 1024);
    expect(facts.diskFreeBytes, 51200 * 1024);
  });

  test('a macOS host keeps bytes as bytes', () {
    final facts = HostFacts.parse(_mac);
    expect(facts.memoryBytes, 17179869184, reason: 'hw.memsize 已是字节，不能再乘 1024');
    expect(facts.load, '1.23 · 4.56 · 7.89');
    expect(facts.uptime, isNull, reason: 'kern.boottime 是时间戳，不是时长，宁可不显示');
  });

  test('a big Linux machine is not misread as bytes', () {
    // 1 TiB of RAM, in kB: more than any "looks like bytes" heuristic.
    final facts = HostFacts.parse('os=Linux\nmem_kb=1073741824\n');
    expect(facts.memoryBytes, 1073741824 * 1024);
  });

  test('a host that answers nothing yields nothing, not zeros', () {
    final facts = HostFacts.parse('os=\nkernel=\nunknown line\n\n');
    expect(facts.any, isFalse);
    expect(facts.memoryBytes, isNull);
    expect(facts.cpus, isNull);
    expect(facts.diskTotalBytes, isNull);
  });

  test('a disk line whose mount point contains spaces still parses', () {
    final facts = HostFacts.parse('disk=/dev/sda1 204800 102400 102400 50% /mnt/my drive\n');
    expect(facts.diskTotalBytes, 204800 * 1024);
    expect(facts.diskFreeBytes, 102400 * 1024);
  });
}
