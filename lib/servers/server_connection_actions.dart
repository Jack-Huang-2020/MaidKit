import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:island_ui_foundation/island_ui_foundation.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:maid_kit/data/local/app_database.dart';
import 'package:maid_kit/shared/presentation/cloud_file_picker.dart';
import 'package:maid_kit/shared/presentation/maidkit_alert.dart';
import 'server_models.dart';
import 'server_providers.dart';
import 'terminal_tabs_provider.dart';

/// Ensures the server is connected, then opens the reusable cloud file picker.
///
/// Returns `null` if the user cancels or the connection cannot be established.
Future<List<CloudPickedPath>?> pickRemotePaths(
  BuildContext context,
  WidgetRef ref,
  Server server, {
  String? title,
  String initialPath = '.',
  CloudFilePickerSelection selection = CloudFilePickerSelection.file,
  bool allowMultiple = false,
}) async {
  final manager = ref.read(connectionManagerProvider);
  if (manager.clientFor(server.id) == null) {
    final connected = await connectForStatistics(context, ref, server);
    if (!connected || !context.mounted) return null;
  }
  return showCloudFilePicker(
    context,
    sftp: () => manager.withClient(server.id, (client) => client.sftp()),
    title: title,
    subtitle: server.name,
    initialPath: initialPath,
    selection: selection,
    allowMultiple: allowMultiple,
  );
}

Future<bool> connectForStatistics(
  BuildContext context,
  WidgetRef ref,
  Server server,
) async {
  HostKeyPrompt? approvedHostKey;
  try {
    final credential = await ref
        .read(serverRepositoryProvider)
        .credentialFor(server);
    final proxy = await ref.read(serverRepositoryProvider).proxyFor(server);
    await ref
        .read(connectionManagerProvider)
        .connect(
          server,
          credential,
          (prompt) async {
            final approved = await _approveHostKey(context, prompt);
            if (approved) approvedHostKey = prompt;
            return approved;
          },
          knownHostKeyFingerprint: server.hostKeyFingerprint,
          proxy: proxy,
        );
    await ref.read(serverRepositoryProvider).markConnected(server.id);
    if (approvedHostKey != null) {
      await ref
          .read(serverRepositoryProvider)
          .rememberHostKey(server.id, approvedHostKey!);
    }
  } catch (error) {
    if (context.mounted) {
      showStyledSnackBar(
        message: error.toString(),
        title: 'serverCannotConnect'.tr(),
        icon: Symbols.link_off_rounded,
        accentColor: Theme.of(context).colorScheme.error,
      );
    }
    return false;
  }

  return true;
}

Future<bool> shouldReconnectAndRetry(
  BuildContext context,
  Object error,
  Server server,
) {
  if (error is! ServerConnectionRequiredException) {
    return Future.value(false);
  }
  return showMaidKitReconnectAlert(server.name);
}

Future<bool> openTerminalSession(
  BuildContext context,
  WidgetRef ref,
  Server server, {
  String? initialDirectory,
  String? paneId,
}) async {
  HostKeyPrompt? approvedHostKey;
  final loading = showMaidKitLoadingModal(
    context,
    message: 'serverOpeningTerminal'.tr(args: [server.name]),
  );
  try {
    final credential = await ref
        .read(serverRepositoryProvider)
        .credentialFor(server);
    final proxy = await ref.read(serverRepositoryProvider).proxyFor(server);
    await ref
        .read(terminalTabsProvider.notifier)
        .open(
          server,
          credential,
          (prompt) async {
            // A host-key prompt must remain interactive, so release the blocking
            // loading overlay before presenting it.
            loading.dismiss();
            final approved = await _approveHostKey(context, prompt);
            if (approved) approvedHostKey = prompt;
            return approved;
          },
          knownHostKeyFingerprint: server.hostKeyFingerprint,
          initialDirectory: initialDirectory,
          paneId: paneId,
          proxy: proxy,
        );
    if (approvedHostKey != null) {
      await ref
          .read(serverRepositoryProvider)
          .rememberHostKey(server.id, approvedHostKey!);
    }
    return true;
  } catch (error) {
    if (context.mounted) {
      showStyledSnackBar(
        message: error.toString(),
        title: 'serverCannotOpenTerminal'.tr(),
        icon: Symbols.terminal_rounded,
        accentColor: Theme.of(context).colorScheme.error,
      );
    }
    return false;
  } finally {
    loading.dismiss();
  }
}

/// Opens the terminal appropriate for [server]'s transport: serial, local
/// shell, or SSH. Returns whether the terminal tab was opened.
Future<bool> openTerminalFor(
  BuildContext context,
  WidgetRef ref,
  Server server, {
  String? paneId,
}) {
  if (server.connectionType == ServerConnectionType.serial.name) {
    return openSerialTerminalSession(context, ref, server, paneId: paneId);
  }
  if (server.connectionType == ServerConnectionType.local.name) {
    return openLocalTerminalSession(context, ref, server, paneId: paneId);
  }
  return openTerminalSession(context, ref, server, paneId: paneId);
}

/// Opens a terminal over [server]'s local serial port. Returns whether the
/// terminal tab was opened.
Future<bool> openSerialTerminalSession(
  BuildContext context,
  WidgetRef ref,
  Server server, {
  String? paneId,
}) async {
  if (!serialPortsSupported) {
    if (context.mounted) {
      showStyledSnackBar(
        message: 'serverSerialNotSupported'.tr(),
        title: 'serverCannotOpenSerialTerminal'.tr(),
        icon: Symbols.terminal_rounded,
        accentColor: Theme.of(context).colorScheme.error,
      );
    }
    return false;
  }
  final loading = showMaidKitLoadingModal(
    context,
    message: 'serverOpeningSerialTerminal'.tr(args: [server.name]),
  );
  try {
    await ref
        .read(terminalTabsProvider.notifier)
        .openSerial(server, paneId: paneId);
    return true;
  } catch (error) {
    if (context.mounted) {
      showStyledSnackBar(
        message: error.toString(),
        title: 'serverCannotOpenSerialTerminal'.tr(),
        icon: Symbols.terminal_rounded,
        accentColor: Theme.of(context).colorScheme.error,
      );
    }
    return false;
  } finally {
    loading.dismiss();
  }
}

/// Opens a terminal on the machine MaidKit runs on. No SSH connection or
/// credentials are involved: the shell is spawned as a local process.
/// Returns whether the terminal tab was opened.
Future<bool> openLocalTerminalSession(
  BuildContext context,
  WidgetRef ref,
  Server server, {
  String? paneId,
  String? initialDirectory,
}) async {
  final loading = showMaidKitLoadingModal(
    context,
    message: 'serverOpeningTerminal'.tr(args: [server.name]),
  );
  try {
    await ref
        .read(terminalTabsProvider.notifier)
        .openLocal(server, paneId: paneId, initialDirectory: initialDirectory);
    return true;
  } catch (error) {
    if (context.mounted) {
      showStyledSnackBar(
        message: error.toString(),
        title: 'serverCannotOpenTerminal'.tr(),
        icon: Symbols.terminal_rounded,
        accentColor: Theme.of(context).colorScheme.error,
      );
    }
    return false;
  } finally {
    loading.dismiss();
  }
}

Future<bool> _approveHostKey(BuildContext context, HostKeyPrompt prompt) async {
  return await showMaidKitOverlayDialog<bool>(
        barrierDismissible: false,
        builder: (context, close) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Symbols.verified_user_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    size: 36,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'serverVerifyHostKey'.tr(),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    prompt.replacesExisting
                        ? 'serverHostKeyChanged'.tr()
                        : 'serverHostKeyNew'.tr(),
                  ),
                  const SizedBox(height: 16),
                  SelectableText('${prompt.algorithm}\n${prompt.fingerprint}'),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => close(false),
                        child: const Text('serverReject').tr(),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => close(true),
                        child: const Text('serverApprove').tr(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ) ??
      false;
}
