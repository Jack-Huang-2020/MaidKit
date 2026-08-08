/// One point in the live activity history used by the Activity tab charts.
class ActivitySample {
  const ActivitySample({
    required this.at,
    this.cpuPercent,
    this.load1,
    this.load5,
    this.load15,
    this.cpuCount,
    this.memoryUsedKb,
    this.memoryTotalKb,
    this.swapUsedKb,
    this.swapTotalKb,
    this.diskUsedKb,
    this.diskTotalKb,
    this.netRxBytes,
    this.netTxBytes,
    this.netRxBps,
    this.netTxBps,
    this.uptime,
  });

  final DateTime at;
  final double? cpuPercent;
  final double? load1;
  final double? load5;
  final double? load15;
  final int? cpuCount;
  final int? memoryUsedKb;
  final int? memoryTotalKb;
  final int? swapUsedKb;
  final int? swapTotalKb;
  final int? diskUsedKb;
  final int? diskTotalKb;

  /// Cumulative counters from `/proc/net/dev` (all non-loopback interfaces).
  final int? netRxBytes;
  final int? netTxBytes;

  /// Bytes/sec derived from consecutive samples.
  final double? netRxBps;
  final double? netTxBps;
  final Duration? uptime;

  double? get memoryPercent {
    final used = memoryUsedKb;
    final total = memoryTotalKb;
    if (used == null || total == null || total == 0) return null;
    return (used / total * 100).clamp(0, 100);
  }

  double? get swapPercent {
    final used = swapUsedKb;
    final total = swapTotalKb;
    if (used == null || total == null || total == 0) return null;
    return (used / total * 100).clamp(0, 100);
  }

  double? get diskPercent {
    final used = diskUsedKb;
    final total = diskTotalKb;
    if (used == null || total == null || total == 0) return null;
    return (used / total * 100).clamp(0, 100);
  }

  /// Load average normalized to a rough 0–100% scale using CPU count.
  double? get loadPercent {
    final load = load1;
    final cpus = cpuCount;
    if (load == null || cpus == null || cpus == 0) return null;
    return (load / cpus * 100).clamp(0, 200);
  }
}

/// Raw counters collected in a single SSH round-trip; deltas are computed in the UI.
class ActivityCounters {
  const ActivityCounters({
    required this.at,
    this.cpuIdle,
    this.cpuTotal,
    this.cpuPercent,
    this.load1,
    this.load5,
    this.load15,
    this.cpuCount,
    this.memoryTotalKb,
    this.memoryAvailableKb,
    this.swapTotalKb,
    this.swapFreeKb,
    this.diskTotalKb,
    this.diskAvailableKb,
    this.netRxBytes,
    this.netTxBytes,
    this.uptime,
  });

  final DateTime at;
  final int? cpuIdle;
  final int? cpuTotal;

  /// Direct CPU utilization for platforms without cumulative CPU counters.
  final double? cpuPercent;
  final double? load1;
  final double? load5;
  final double? load15;
  final int? cpuCount;
  final int? memoryTotalKb;
  final int? memoryAvailableKb;
  final int? swapTotalKb;
  final int? swapFreeKb;
  final int? diskTotalKb;
  final int? diskAvailableKb;
  final int? netRxBytes;
  final int? netTxBytes;
  final Duration? uptime;
  ActivitySample toSample({ActivityCounters? previous}) {
    double? cpuPercent = this.cpuPercent;
    double? netRxBps;
    double? netTxBps;
    if (cpuPercent == null &&
        previous != null &&
        cpuIdle != null &&
        cpuTotal != null &&
        previous.cpuIdle != null &&
        previous.cpuTotal != null) {
      final idleDelta = cpuIdle! - previous.cpuIdle!;
      final totalDelta = cpuTotal! - previous.cpuTotal!;
      if (totalDelta > 0) {
        cpuPercent = ((1 - idleDelta / totalDelta) * 100).clamp(0, 100);
      }
    }
    if (previous != null &&
        netRxBytes != null &&
        netTxBytes != null &&
        previous.netRxBytes != null &&
        previous.netTxBytes != null) {
      final seconds = at.difference(previous.at).inMilliseconds / 1000.0;
      if (seconds > 0) {
        final rxDelta = netRxBytes! - previous.netRxBytes!;
        final txDelta = netTxBytes! - previous.netTxBytes!;
        if (rxDelta >= 0) netRxBps = rxDelta / seconds;
        if (txDelta >= 0) netTxBps = txDelta / seconds;
      }
    }
    final memUsed = memoryTotalKb == null || memoryAvailableKb == null
        ? null
        : memoryTotalKb! - memoryAvailableKb!;
    final swapUsed = swapTotalKb == null || swapFreeKb == null
        ? null
        : swapTotalKb! - swapFreeKb!;
    final diskUsed = diskTotalKb == null || diskAvailableKb == null
        ? null
        : diskTotalKb! - diskAvailableKb!;
    return ActivitySample(
      at: at,
      cpuPercent: cpuPercent,
      load1: load1,
      load5: load5,
      load15: load15,
      cpuCount: cpuCount,
      memoryUsedKb: memUsed,
      memoryTotalKb: memoryTotalKb,
      swapUsedKb: swapUsed,
      swapTotalKb: swapTotalKb,
      diskUsedKb: diskUsed,
      diskTotalKb: diskTotalKb,
      netRxBytes: netRxBytes,
      netTxBytes: netTxBytes,
      netRxBps: netRxBps,
      netTxBps: netTxBps,
      uptime: uptime,
    );
  }
}
