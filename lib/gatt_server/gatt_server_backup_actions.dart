import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:universal_ble_example/data/gatt_server_config_codec.dart';
import 'package:universal_ble_example/data/gatt_server_storage.dart';
import 'package:universal_ble_example/gatt_server/profile_files/gatt_server_profile_files.dart';
import 'package:universal_ble_example/models/gatt_server_config.dart';

/// File-based import / export for saved GATT server profiles (JSON).
abstract final class GattServerBackupActions {
  static const _exportFileName = 'gatt_server_profiles.json';

  static Future<void> exportProfilesToFile(
    BuildContext context,
    List<GattServerConfig> configs,
  ) async {
    if (!context.mounted) return;
    if (configs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to export.')),
      );
      return;
    }
    final text = GattServerConfigCodec.encodeList(configs);
    final bytes = Uint8List.fromList(utf8.encode(text));

    final path = await FilePicker.saveFile(
      dialogTitle: 'Export GATT profiles',
      fileName: _exportFileName,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: bytes,
    );
    if (!context.mounted) return;
    if (path != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to $path')),
      );
    } else if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Export finished. Check your browser downloads for the .json file.',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Export cancelled.')),
      );
    }
  }

  static Future<void> importProfilesFromFile(
    BuildContext context, {
    required GattServerStorage storage,
    required VoidCallback onDone,
  }) async {
    if (!context.mounted) return;
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Import GATT profiles',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      allowMultiple: false,
      withData: true,
    );
    if (!context.mounted) return;
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final String? raw = await _readPickedUtf8(file);
    if (raw == null || raw.trim().isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not read the file. On desktop, try again or pick a local .json file.',
          ),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    await _applyImport(context, storage: storage, raw: raw, onDone: onDone);
  }

  static Future<String?> _readPickedUtf8(PlatformFile file) async {
    if (file.bytes != null) {
      return utf8.decode(file.bytes!);
    }
    if (file.path != null && !kIsWeb) {
      try {
        return await readUtf8File(file.path!);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static Future<void> _applyImport(
    BuildContext context, {
    required GattServerStorage storage,
    required String raw,
    required VoidCallback onDone,
  }) async {
    try {
      final list = GattServerConfigCodec.decodeList(raw);
      await storage.mergeImportedConfigs(list);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported ${list.length} profile(s).')),
      );
      onDone();
    } on FormatException catch (e) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Invalid JSON'),
          content: Text(e.message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }
}
