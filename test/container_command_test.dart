import 'package:flutter_test/flutter_test.dart';
import 'package:maid_kit/containers/container_models.dart';

void main() {
  test('builds a safely quoted interactive exec command', () {
    final command = buildContainerExecCommand(
      runtime: ContainerRuntime.docker,
      containerId: "api'one",
      command: 'nginx -s reload',
    );

    expect(command, "docker exec -it 'api'\\''one' sh -c 'nginx -s reload'");
  });

  test('builds attach and scope scripts', () {
    final attach = buildContainerAttachCommand(
      runtime: ContainerRuntime.podman,
      containerId: 'web',
    );

    expect(attach, "podman attach 'web'");
    expect(
      buildContainerTerminalScript(scope: ContainerScope.user, command: attach),
      "exec podman attach 'web'",
    );
    expect(
      buildContainerTerminalScript(scope: ContainerScope.root, command: attach),
      "exec sudo -S podman attach 'web'",
    );
  });
}
