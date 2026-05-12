import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

class GattServerConfig {
  final String id;
  final String profileName;
  final String localName;
  final ManufacturerData? manufacturerData;
  final List<BlePeripheralService> services;

  const GattServerConfig({
    required this.id,
    required this.profileName,
    required this.localName,
    this.manufacturerData,
    this.services = const [],
  });

  GattServerConfig copyWith({
    String? id,
    String? profileName,
    String? localName,
    ManufacturerData? manufacturerData,
    List<BlePeripheralService>? services,
  }) {
    return GattServerConfig(
      id: id ?? this.id,
      profileName: profileName ?? this.profileName,
      localName: localName ?? this.localName,
      manufacturerData: manufacturerData ?? this.manufacturerData,
      services: services ?? this.services,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'profileName': profileName,
        'localName': localName,
        'manufacturerData': manufacturerData?.toUint8List().toList(),
        'services': services.map((e) => e.toJson()).toList(),
      };

  factory GattServerConfig.fromJson(Map<String, dynamic> json) {
    final rawManufacturerData = json['manufacturerData'];
    final manufacturerDataBytes = switch (rawManufacturerData) {
      Uint8List bytes => bytes,
      List<dynamic> list => Uint8List.fromList(list.cast<int>()),
      _ => null,
    };
    return GattServerConfig(
      id: json['id'] as String,
      profileName: json['profileName'] as String,
      localName: json['localName'] as String? ?? 'UniBle',
      manufacturerData: manufacturerDataBytes == null
          ? null
          : ManufacturerData.fromData(manufacturerDataBytes),
      services: (json['services'] as List<dynamic>? ?? const [])
          .map(
            (e) => BlePeripheralService.fromJson(e as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}
