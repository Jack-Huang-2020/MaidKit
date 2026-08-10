/// A container runtime available on a managed server.
enum ContainerRuntime { docker, podman }

/// Containers can belong either to the connected user or to the host root
/// environment. Root operations require passwordless sudo on the server.
enum ContainerScope { user, root }

/// The interactive command run in a container terminal.
String buildContainerExecCommand({
  required ContainerRuntime runtime,
  required String containerId,
  required String command,
}) {
  final flags = '-it';
  return '${runtime.name} exec $flags ${_shellQuote(containerId)} '
      'sh -c ${_shellQuote(command)}';
}

/// The interactive command that attaches to a running container's main
/// process.
String buildContainerAttachCommand({
  required ContainerRuntime runtime,
  required String containerId,
}) => '${runtime.name} attach ${_shellQuote(containerId)}';

/// Wraps an interactive container command in the remote shell's privilege
/// boundary.
String buildContainerTerminalScript({
  required ContainerScope scope,
  required String command,
}) => switch (scope) {
  ContainerScope.user => 'exec $command',
  // `-S` keeps the password prompt on the terminal's stdin, so interactive
  // sessions can use either passwordless sudo or the configured user password
  // without embedding a credential in the initial command script.
  ContainerScope.root => 'exec sudo -S $command',
};

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// Lifecycle actions for a single container (`docker|podman <verb> <id>`).
///
/// [remove] maps to `rm`. When the container is still running, callers should
/// pass `force: true` to `runContainerAction` so the runtime uses `rm -f`.
enum ContainerAction { start, stop, restart, pause, unpause, kill, remove }

extension ContainerActionX on ContainerAction {
  /// Short label for menus and confirmation buttons.
  String get label => switch (this) {
    ContainerAction.start => 'Start',
    ContainerAction.stop => 'Stop',
    ContainerAction.restart => 'Restart',
    ContainerAction.pause => 'Pause',
    ContainerAction.unpause => 'Unpause',
    ContainerAction.kill => 'Kill',
    ContainerAction.remove => 'Delete',
  };

  /// Past-tense snackbar title fragment, e.g. "Container stopped".
  String get pastLabel => switch (this) {
    ContainerAction.start => 'started',
    ContainerAction.stop => 'stopped',
    ContainerAction.restart => 'restarted',
    ContainerAction.pause => 'paused',
    ContainerAction.unpause => 'unpaused',
    ContainerAction.kill => 'killed',
    ContainerAction.remove => 'deleted',
  };

  /// Subcommand verb passed to the runtime CLI (not always [name]).
  String get cliVerb => switch (this) {
    ContainerAction.remove => 'rm',
    _ => name,
  };

  /// Whether the action can interrupt or destroy a running workload.
  bool get isDestructive => switch (this) {
    ContainerAction.stop ||
    ContainerAction.kill ||
    ContainerAction.remove => true,
    _ => false,
  };

  /// Whether the UI should prompt before running the action.
  bool get requiresConfirmation =>
      isDestructive || this == ContainerAction.restart;
}

/// Actions available for a local container image.
enum ImageAction { remove }

/// Lifecycle / maintenance actions for a linked compose project.
///
/// Labels are short menu titles; [composeArgs] is the `compose` subcommand
/// string appended after `docker|podman compose -p <name>`.
enum ComposeProjectAction {
  /// `compose pull` — fetch service images without starting containers.
  pull,

  /// `compose up -d` — create/start services in the background.
  up,

  /// `compose stop` — stop running services; leave containers in place.
  stop,

  /// `compose restart` — restart existing containers.
  restart,

  /// `compose up -d --force-recreate` — recreate containers even if config is unchanged.
  recreate;

  /// Short label for menus and snackbars.
  String get label => switch (this) {
    ComposeProjectAction.pull => 'Pull images',
    ComposeProjectAction.up => 'Start',
    ComposeProjectAction.stop => 'Stop',
    ComposeProjectAction.restart => 'Restart',
    ComposeProjectAction.recreate => 'Force recreate',
  };

  /// Present-participle used in loading / terminal titles.
  String get progressLabel => switch (this) {
    ComposeProjectAction.pull => 'Pulling images',
    ComposeProjectAction.up => 'Starting',
    ComposeProjectAction.stop => 'Stopping',
    ComposeProjectAction.restart => 'Restarting',
    ComposeProjectAction.recreate => 'Force recreating',
  };

  /// Arguments after `compose -p <project>`.
  String get composeArgs => switch (this) {
    ComposeProjectAction.pull => 'pull',
    ComposeProjectAction.up => 'up -d',
    ComposeProjectAction.stop => 'stop',
    ComposeProjectAction.restart => 'restart',
    ComposeProjectAction.recreate => 'up -d --force-recreate',
  };
}

class ServerContainer {
  const ServerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.status,
    this.composeProject,
  });

  final String id;
  final String name;
  final String image;
  final String state;
  final String status;

  /// The Docker or Podman Compose project label assigned to this container.
  final String? composeProject;
}

/// Live resource sample from `docker stats` / `podman stats`.
class ContainerStats {
  const ContainerStats({
    required this.id,
    required this.name,
    this.cpuPercent,
    this.memUsage = '',
    this.memPercent,
    this.memUsedBytes,
    this.memLimitBytes,
    this.netIO = '',
    this.netRxBytes,
    this.netTxBytes,
    this.blockIO = '',
    this.blockReadBytes,
    this.blockWriteBytes,
    this.pids,
  });

  final String id;
  final String name;
  final double? cpuPercent;
  final String memUsage;
  final double? memPercent;
  final int? memUsedBytes;
  final int? memLimitBytes;
  final String netIO;
  final int? netRxBytes;
  final int? netTxBytes;
  final String blockIO;
  final int? blockReadBytes;
  final int? blockWriteBytes;
  final int? pids;
}

class ContainerEnvironment {
  const ContainerEnvironment({
    required this.runtime,
    required this.scope,
    this.containers = const [],
    this.error,
  });

  final ContainerRuntime runtime;
  final ContainerScope scope;
  final List<ServerContainer> containers;
  final String? error;

  bool get isAvailable => error == null;
}

/// A local image from `docker images` / `podman images`.
class ServerContainerImage {
  const ServerContainerImage({
    required this.id,
    required this.repository,
    required this.tag,
    required this.size,
    required this.created,
    this.unused = false,
  });

  final String id;
  final String repository;
  final String tag;

  /// Human-readable size from the runtime (e.g. `128MB`).
  final String size;

  /// Relative created age from the runtime (e.g. `2 weeks ago`).
  final String created;

  /// True when no container references this image (includes dangling images).
  final bool unused;

  /// `repository:tag`, or the short id when the image is dangling.
  String get reference {
    final repo = repository.trim();
    final imageTag = tag.trim();
    if (repo.isEmpty || repo == '<none>') {
      return id;
    }
    if (imageTag.isEmpty || imageTag == '<none>') {
      return repo;
    }
    return '$repo:$imageTag';
  }

  bool get isDangling {
    final repo = repository.trim();
    final imageTag = tag.trim();
    return repo.isEmpty ||
        repo == '<none>' ||
        imageTag.isEmpty ||
        imageTag == '<none>';
  }

  ServerContainerImage copyWith({bool? unused}) => ServerContainerImage(
    id: id,
    repository: repository,
    tag: tag,
    size: size,
    created: created,
    unused: unused ?? this.unused,
  );
}

/// Images listed for one runtime + scope combination on a server.
class ImageEnvironment {
  const ImageEnvironment({
    required this.runtime,
    required this.scope,
    this.images = const [],
    this.error,
  });

  final ContainerRuntime runtime;
  final ContainerScope scope;
  final List<ServerContainerImage> images;
  final String? error;

  bool get isAvailable => error == null;

  int get unusedCount => images.where((image) => image.unused).length;
}

/// Structured result of `docker|podman inspect` for a single container.
class ContainerInspectDetail {
  const ContainerInspectDetail({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.status,
    required this.created,
    required this.startedAt,
    required this.finishedAt,
    required this.exitCode,
    required this.platform,
    required this.restartPolicy,
    required this.networkMode,
    required this.workingDir,
    required this.user,
    required this.entrypoint,
    required this.command,
    required this.env,
    required this.ports,
    required this.binds,
    required this.mounts,
    required this.labels,
    required this.networks,
    required this.rawJson,
  });

  final String id;
  final String name;
  final String image;
  final String state;
  final String status;
  final String? created;
  final String? startedAt;
  final String? finishedAt;
  final int? exitCode;
  final String? platform;
  final String restartPolicy;
  final String networkMode;
  final String? workingDir;
  final String? user;
  final List<String> entrypoint;
  final List<String> command;
  final List<String> env;
  final List<String> ports;
  final List<String> binds;
  final List<String> mounts;
  final Map<String, String> labels;
  final List<String> networks;
  final String rawJson;

  bool get isRunning {
    final value = state.toLowerCase();
    return value.contains('running') ||
        value == 'up' ||
        value.contains('paused');
  }

  bool get isPaused => state.toLowerCase().contains('paused');

  /// Best-effort `run` command reconstructed from inspect data.
  ///
  /// Not every HostConfig flag is preserved; this covers the options MaidKit
  /// exposes in the run form and common production mounts/ports/env.
  String rerunCommand(ContainerRuntime runtime) {
    final parts = <String>[runtime.name, 'run', '-d'];
    final cleanName = name.startsWith('/') ? name.substring(1) : name;
    if (cleanName.isNotEmpty) {
      parts.addAll(['--name', cleanName]);
    }
    if (restartPolicy.isNotEmpty && restartPolicy != 'no') {
      parts.addAll(['--restart', restartPolicy]);
    }
    if (networkMode.isNotEmpty &&
        networkMode != 'default' &&
        networkMode != 'bridge') {
      parts.addAll(['--network', networkMode]);
    }
    if (user != null && user!.isNotEmpty) {
      parts.addAll(['--user', user!]);
    }
    if (workingDir != null && workingDir!.isNotEmpty) {
      parts.addAll(['-w', workingDir!]);
    }
    for (final port in ports) {
      parts.addAll(['-p', port]);
    }
    for (final bind in binds) {
      parts.addAll(['-v', bind]);
    }
    for (final variable in env) {
      // Skip PATH-like image defaults that make re-run noisy when empty-ish.
      if (variable.startsWith('PATH=')) continue;
      parts.addAll(['-e', variable]);
    }
    for (final entry in labels.entries) {
      // Compose labels are noisy in re-run copies.
      if (entry.key.startsWith('com.docker.compose.') ||
          entry.key.startsWith('io.podman.compose.')) {
        continue;
      }
      parts.addAll(['--label', '${entry.key}=${entry.value}']);
    }
    parts.add(image.isEmpty ? '<image>' : image);
    if (command.isNotEmpty) {
      parts.addAll(command);
    }
    return parts.map(_shellToken).join(' ');
  }

  static String _shellToken(String value) {
    if (RegExp(r'^[a-zA-Z0-9_./:@%+=,-]+$').hasMatch(value)) return value;
    return "'${value.replaceAll("'", "'\\''")}'";
  }
}
