import 'dart:convert';

import 'package:universal_ble_example/data/prefs_async.dart';
import 'package:universal_ble_example/models/gatt_server_config.dart';

class GattServerStorage {
  GattServerStorage._();
  static const _configsKey = 'gatt_server_configs_v1';
  static final GattServerStorage instance = GattServerStorage._();

  Future<List<GattServerConfig>> getConfigs() async {
    final raw = await prefsAsync.getString(_configsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => GattServerConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveConfig(GattServerConfig config) async {
    final configs = await getConfigs();
    final index = configs.indexWhere((element) => element.id == config.id);
    if (index == -1) {
      configs.add(config);
    } else {
      configs[index] = config;
    }
    await _saveAll(configs);
  }

  Future<void> deleteConfig(String id) async {
    final configs = await getConfigs();
    configs.removeWhere((e) => e.id == id);
    await _saveAll(configs);
  }

  Future<GattServerConfig?> getById(String id) async {
    final configs = await getConfigs();
    for (final config in configs) {
      if (config.id == id) return config;
    }
    return null;
  }

  Future<void> mergeImportedConfigs(List<GattServerConfig> incoming) async {
    if (incoming.isEmpty) return;
    final configs = await getConfigs();
    final byId = <String, GattServerConfig>{for (final c in configs) c.id: c};
    for (final c in incoming) {
      byId[c.id] = c;
    }
    await _saveAll(byId.values.toList());
  }

  Future<void> _saveAll(List<GattServerConfig> configs) async {
    final payload = jsonEncode(configs.map((e) => e.toJson()).toList());
    await prefsAsync.setString(_configsKey, payload);
  }
}
