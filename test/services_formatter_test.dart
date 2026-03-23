import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:universal_ble_example/peripheral_details/utils/services_formatter.dart';

void main() {
  group('formatBleServices', () {
    test('renders empty service placeholder', () {
      final services = [
        BleService('180A', []),
      ];

      final formatted = formatBleServices(services);

      expect(
        formatted,
        contains('Service: 0000180a-0000-1000-8000-00805f9b34fb'),
      );
      expect(formatted, contains('The service is empty'));
    });

    test('renders characteristics with properties', () {
      final services = [
        BleService('180A', [
          BleCharacteristic.withMetaData(
            deviceId: 'device-1',
            serviceId: '180A',
            uuid: '2A29',
            properties: [
              CharacteristicProperty.read,
              CharacteristicProperty.notify,
            ],
            descriptors: const [],
          ),
        ]),
      ];

      final formatted = formatBleServices(services);

      expect(
        formatted,
        contains('Service: 0000180a-0000-1000-8000-00805f9b34fb'),
      );
      expect(
        formatted,
        contains('00002a29-0000-1000-8000-00805f9b34fb (read, notify)'),
      );
      expect(formatted, isNot(contains('The service is empty')));
    });
  });
}
