import 'dart:convert';

import 'package:universal_ble_example/models/gatt_server_config.dart';

/// JSON encode/decode for [GattServerConfig] lists (backup / share).
abstract final class GattServerConfigCodec {
  static String encodeList(List<GattServerConfig> configs) {
    return const JsonEncoder.withIndent('  ')
        .convert(configs.map((e) => e.toJson()).toList());
  }

  /// Accepts:
  /// - a JSON array of profile objects
  /// - `{ "configs": [ ... ] }` or `{ "profiles": [ ... ] }`
  /// - a single profile object `{ "profileName": ..., "services": ... }`
  static List<GattServerConfig> decodeList(String raw) {
    final dynamic decoded = jsonDecode(raw);
    final List<dynamic> list;
    if (decoded is List<dynamic>) {
      list = decoded;
    } else if (decoded is Map) {
      final m = Map<String, dynamic>.from(decoded);
      if (m['configs'] is List) {
        list = m['configs']! as List<dynamic>;
      } else if (m['profiles'] is List) {
        list = m['profiles']! as List<dynamic>;
      } else if (m.containsKey('profileName') && m.containsKey('id')) {
        list = [m];
      } else if (m.containsKey('profileName') && m.containsKey('services')) {
        list = [m];
      } else {
        throw const FormatException(
          'Expected a JSON array, or an object with "configs"/"profiles", '
          'or a single profile with profileName and services.',
        );
      }
    } else {
      throw const FormatException('Invalid JSON root type.');
    }
    return list.map((e) {
      final map = Map<String, dynamic>.from(e as Map);
      final id = map['id'];
      if (id == null || (id is String && id.trim().isEmpty)) {
        map['id'] = DateTime.now().microsecondsSinceEpoch.toString();
      }
      return GattServerConfig.fromJson(map);
    }).toList();
  }
}
