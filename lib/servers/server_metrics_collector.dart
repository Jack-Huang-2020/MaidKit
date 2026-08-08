import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'server_models.dart';

abstract interface class ServerMetricsCollector {
  String get id;
  String get label;

  Future<ServerStats?> collect(SSHClient client);
}

/// Selects the first collector that can return a valid result for the host.
class AutoServerMetricsCollector implements ServerMetricsCollector {
  AutoServerMetricsCollector({List<ServerMetricsCollector>? collectors})
    : _collectors =
          collectors ??
          const [
            LinuxProcfsMetricsCollector(),
            MacosSysctlMetricsCollector(),
            UptimeMetricsCollector(),
          ];

  final List<ServerMetricsCollector> _collectors;

  @override
  String get id => 'auto';

  @override
  String get label => 'Automatic';

  @override
  Future<ServerStats?> collect(SSHClient client) async {
    for (final collector in _collectors) {
      try {
        final stats = await collector.collect(client);
        if (stats != null) return stats;
      } catch (_) {
        // Try the next compatible collector.
      }
    }
    return null;
  }
}

class MacosSysctlMetricsCollector implements ServerMetricsCollector {
  const MacosSysctlMetricsCollector();

  @override
  String get id => 'macos-sysctl';

  @override
  String get label => 'macOS sysctl';

  @override
  Future<ServerStats?> collect(SSHClient client) async {
    final output = await _run(client, r"""sh -c '
if [ "$(uname -s 2>/dev/null)" != "Darwin" ]; then exit 1; fi
echo --LOAD--
sysctl -n vm.loadavg 2>/dev/null || true
echo --CPU--
sysctl -n hw.ncpu 2>/dev/null || true
echo --MEMTOTAL--
sysctl -n hw.memsize 2>/dev/null || true
echo --VMSTAT--
vm_stat 2>/dev/null || true
echo --SWAP--
sysctl -n vm.swapusage 2>/dev/null || true
echo --DISK--
df -Pk / 2>/dev/null || true
echo --UPTIME--
sysctl -n kern.boottime 2>/dev/null || true
'""");
    return parseMacosMetricsOutput(output);
  }
}

class LinuxProcfsMetricsCollector implements ServerMetricsCollector {
  const LinuxProcfsMetricsCollector();

  @override
  String get id => 'linux-procfs';

  @override
  String get label => 'Linux procfs';

  @override
  Future<ServerStats?> collect(SSHClient client) async {
    final output = await _run(
      client,
      "sh -c 'cat /proc/loadavg; echo --CPU--; getconf _NPROCESSORS_ONLN 2>/dev/null || nproc; echo --MEM--; cat /proc/meminfo; echo --DISK--; df -Pk / | tail -n 1; echo --UPTIME--; cut -d. -f1 /proc/uptime'",
    );
    final sections = output.split('--CPU--');
    if (sections.length != 2) return null;
    final loads = sections.first.trim().split(RegExp(r'\s+'));
    final load = double.tryParse(loads.first);
    final cpuAndRest = sections[1].split('--MEM--');
    if (cpuAndRest.length != 2 || load == null) return null;
    final memoryAndRest = cpuAndRest[1].split('--DISK--');
    if (memoryAndRest.length != 2) return null;
    final diskAndUptime = memoryAndRest[1].split('--UPTIME--');
    if (diskAndUptime.length != 2) return null;
    int? valueFor(String label) {
      final match = RegExp('$label:\\s+(\\d+)').firstMatch(memoryAndRest[0]);
      return match == null ? null : int.tryParse(match.group(1)!);
    }

    final diskFields = diskAndUptime[0].trim().split(RegExp(r'\s+'));

    return ServerStats(
      collectorId: id,
      updatedAt: DateTime.now(),
      loadAverage: load,
      loadAverage5: loads.length > 1 ? double.tryParse(loads[1]) : null,
      loadAverage15: loads.length > 2 ? double.tryParse(loads[2]) : null,
      cpuCount: int.tryParse(cpuAndRest[0].trim()),
      memoryTotalKb: valueFor('MemTotal'),
      memoryAvailableKb: valueFor('MemAvailable'),
      swapTotalKb: valueFor('SwapTotal'),
      swapFreeKb: valueFor('SwapFree'),
      diskTotalKb: diskFields.length > 1 ? int.tryParse(diskFields[1]) : null,
      diskAvailableKb: diskFields.length > 3
          ? int.tryParse(diskFields[3])
          : null,
      uptime: Duration(seconds: int.tryParse(diskAndUptime[1].trim()) ?? 0),
    );
  }
}

/// Parses the normalized output emitted by [MacosSysctlMetricsCollector].
ServerStats? parseMacosMetricsOutput(String output, {DateTime? now}) {
  final loads = _parseLoadTriple(_metricSection(output, 'LOAD'));
  final load = loads.$1;
  if (load == null) return null;

  final totalBytes = int.tryParse(_metricSection(output, 'MEMTOTAL').trim());
  final availableBytes = _parseMacosAvailableMemory(
    _metricSection(output, 'VMSTAT'),
  );
  final swap = _parseMacosSwap(_metricSection(output, 'SWAP'));
  final diskFields = _lastDataRowFields(_metricSection(output, 'DISK'));
  final bootSeconds = RegExp(
    r'sec\s*=\s*(\d+)',
  ).firstMatch(_metricSection(output, 'UPTIME'))?.group(1);
  final boot = bootSeconds == null ? null : int.tryParse(bootSeconds);
  final currentTime = now ?? DateTime.now();
  final uptime = boot == null
      ? null
      : Duration(
          seconds: (currentTime.millisecondsSinceEpoch ~/ 1000 - boot).clamp(
            0,
            0x7fffffffffffffff,
          ),
        );

  return ServerStats(
    collectorId: 'macos-sysctl',
    updatedAt: currentTime,
    loadAverage: load,
    loadAverage5: loads.$2,
    loadAverage15: loads.$3,
    cpuCount: int.tryParse(_metricSection(output, 'CPU').trim()),
    memoryTotalKb: totalBytes == null ? null : totalBytes ~/ 1024,
    memoryAvailableKb: availableBytes == null ? null : availableBytes ~/ 1024,
    swapTotalKb: swap.$1,
    swapFreeKb: swap.$2,
    diskTotalKb: diskFields.length > 1 ? int.tryParse(diskFields[1]) : null,
    diskAvailableKb: diskFields.length > 3 ? int.tryParse(diskFields[3]) : null,
    uptime: uptime,
  );
}

List<String> _lastDataRowFields(String output) {
  final lines = output
      .trim()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  return lines.isEmpty ? const [] : lines.last.split(RegExp(r'\s+'));
}

/// A portable fallback for POSIX-like hosts where procfs is unavailable.
class UptimeMetricsCollector implements ServerMetricsCollector {
  const UptimeMetricsCollector();

  @override
  String get id => 'uptime';

  @override
  String get label => 'Uptime command';

  @override
  Future<ServerStats?> collect(SSHClient client) async {
    final output = await _run(client, 'uptime');
    final match = RegExp(
      r'load averages?:\s*(.*)',
      caseSensitive: false,
    ).firstMatch(output);
    final loads = _parseLoadTriple(match?.group(1));
    if (loads.$1 == null) return null;
    return ServerStats(
      collectorId: id,
      updatedAt: DateTime.now(),
      loadAverage: loads.$1,
      loadAverage5: loads.$2,
      loadAverage15: loads.$3,
    );
  }
}

String _metricSection(String output, String label) {
  final start = output.indexOf('--$label--');
  if (start < 0) return '';
  final after = start + label.length + 4;
  final next = output.indexOf('--', after);
  return (next < 0 ? output.substring(after) : output.substring(after, next))
      .trim();
}

(double?, double?, double?) _parseLoadTriple(String? output) {
  final values = RegExp(r'[0-9]+(?:\.[0-9]+)?')
      .allMatches(output ?? '')
      .map((match) => double.tryParse(match.group(0)!))
      .whereType<double>()
      .toList();
  double? at(int index) => values.length > index ? values[index] : null;
  return (at(0), at(1), at(2));
}

int? _parseMacosAvailableMemory(String output) {
  final pageSize = int.tryParse(
    RegExp(r'page size of (\d+) bytes').firstMatch(output)?.group(1) ?? '',
  );
  if (pageSize == null) return null;
  int? pages(String label) => int.tryParse(
    RegExp('$label:\\s+(\\d+)').firstMatch(output)?.group(1) ?? '',
  );
  final availablePages = [
    pages('Pages free'),
    pages('Pages inactive'),
    pages('Pages speculative'),
  ].whereType<int>().toList();
  if (availablePages.isEmpty) return null;
  return availablePages.fold<int>(0, (sum, value) => sum + value) * pageSize;
}

(int?, int?) _parseMacosSwap(String output) {
  int? value(String label) {
    final match = RegExp(
      '$label\\s*=\\s*([0-9]+(?:\\.[0-9]+)?)([KMGT])',
      caseSensitive: false,
    ).firstMatch(output);
    if (match == null) return null;
    final amount = double.tryParse(match.group(1)!);
    if (amount == null) return null;
    final multiplier = switch (match.group(2)!.toUpperCase()) {
      'K' => 1,
      'M' => 1024,
      'G' => 1024 * 1024,
      'T' => 1024 * 1024 * 1024,
      _ => 1,
    };
    return (amount * multiplier).round();
  }

  return (value('total'), value('free'));
}

Future<String> _run(SSHClient client, String command) async {
  final session = await client.execute(command);
  final output = await utf8.decoder.bind(session.stdout).join();
  await session.done;
  return output;
}
