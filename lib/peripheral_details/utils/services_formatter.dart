import 'package:universal_ble/universal_ble.dart';

String formatBleServices(List<BleService> services) {
  final buffer = StringBuffer();
  for (final service in services) {
    buffer.writeln('Discovered Services: ${service.uuid}');
    if (service.characteristics.isEmpty) {
      buffer.writeln('  The service is empty');
    } else {
      for (final characteristic in service.characteristics) {
        final properties =
            characteristic.properties.map((p) => p.name).join(', ');
        buffer.writeln('  ${characteristic.uuid} ($properties)');
      }
    }
    buffer.writeln();
  }
  return buffer.toString().trim();
}
