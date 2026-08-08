import 'package:flutter_test/flutter_test.dart';
import 'package:maid_kit/servers/activity_models.dart';
import 'package:maid_kit/servers/server_metrics_collector.dart';

void main() {
  test('parses macOS sysctl metrics output', () {
    final now = DateTime.fromMillisecondsSinceEpoch(2_000_000_000_000);
    final bootSeconds = now.millisecondsSinceEpoch ~/ 1000 - 86_400;
    final stats = parseMacosMetricsOutput('''
--LOAD--
{ 1.25 0.75 0.50 }
--CPU--
10
--MEMTOTAL--
17179869184
--VMSTAT--
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               100.
Pages inactive:                           200.
Pages speculative:                         50.
--SWAP--
total = 4096.00M  used = 1024.00M  free = 3072.00M
--DISK--
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s1 104857600 52428800 52428800 50% /
--UPTIME--
{ sec = $bootSeconds, usec = 0 } Mon Jan  1 00:00:00 2024
''', now: now);

    expect(stats, isNotNull);
    expect(stats!.collectorId, 'macos-sysctl');
    expect(stats.loadAverage, 1.25);
    expect(stats.loadAverage5, 0.75);
    expect(stats.loadAverage15, 0.5);
    expect(stats.cpuCount, 10);
    expect(stats.memoryTotalKb, 16 * 1024 * 1024);
    expect(stats.memoryAvailableKb, 350 * 16);
    expect(stats.swapTotalKb, 4096 * 1024);
    expect(stats.swapFreeKb, 3072 * 1024);
    expect(stats.diskTotalKb, 104857600);
    expect(stats.diskAvailableKb, 52428800);
    expect(stats.uptime, const Duration(days: 1));
  });

  test('rejects output without a macOS load average', () {
    expect(parseMacosMetricsOutput('--CPU--\n8\n'), isNull);
  });

  test('parses Windows PowerShell metrics output', () {
    final now = DateTime(2026, 8, 8);
    final stats = parseWindowsMetricsOutput('''
--WINDOWS--
--LOAD--
2.4
--CPU--
8
--MEM--
MemTotal: 16777216
MemAvailable: 8388608
--SWAP--
SwapTotal: 4194304
SwapFree: 3145728
--DISK--
DiskTotal: 52428800
DiskAvailable: 26214400
--UPTIME--
86400
''', now: now);

    expect(stats, isNotNull);
    expect(stats!.collectorId, 'windows-powershell');
    expect(stats.loadAverage, 2.4);
    expect(stats.cpuCount, 8);
    expect(stats.memoryTotalKb, 16777216);
    expect(stats.memoryAvailableKb, 8388608);
    expect(stats.swapTotalKb, 4194304);
    expect(stats.swapFreeKb, 3145728);
    expect(stats.diskTotalKb, 52428800);
    expect(stats.diskAvailableKb, 26214400);
    expect(stats.uptime, const Duration(days: 1));
    expect(stats.updatedAt, now);
  });

  test('activity counters preserve direct Windows CPU utilization', () {
    final sample = ActivityCounters(
      at: DateTime(2026, 8, 8),
      cpuPercent: 37.5,
      memoryTotalKb: 100,
      memoryAvailableKb: 25,
    ).toSample();

    expect(sample.cpuPercent, 37.5);
    expect(sample.memoryUsedKb, 75);
  });
}
