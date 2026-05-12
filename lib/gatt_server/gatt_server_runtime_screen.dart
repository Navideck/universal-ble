import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:universal_ble_example/data/gatt_server_storage.dart';
import 'package:universal_ble_example/models/gatt_server_config.dart';

class GattServerRuntimeScreen extends StatefulWidget {
  final String configId;

  const GattServerRuntimeScreen({
    super.key,
    required this.configId,
  });

  @override
  State<GattServerRuntimeScreen> createState() =>
      _GattServerRuntimeScreenState();
}

class _GattServerRuntimeScreenState extends State<GattServerRuntimeScreen> {
  final List<String> _logs = <String>[];
  final Map<String, Set<String>> _subscribedClientsByCharacteristic = {};
  final Set<String> _addedServiceIds = <String>{};
  final Map<String, List<int>> _characteristicIncomingData =
      <String, List<int>>{};
  final Map<String, List<int>> _characteristicUpdatedData =
      <String, List<int>>{};

  GattServerConfig? _config;
  bool _isLoadingConfig = true;
  bool _supportsPeripheralMode = false;
  bool _isCheckingReadiness = true;
  PeripheralReadinessState? _readinessState;
  PeripheralAdvertisingState _advertisingState =
      PeripheralAdvertisingState.idle;

  StreamSubscription<BlePeripheralEvent>? _advertisingStateStreamSub;
  StreamSubscription<BlePeripheralEvent>? _characteristicSubscriptionStreamSub;
  StreamSubscription<BlePeripheralEvent>? _connectionStateStreamSub;
  StreamSubscription<BlePeripheralEvent>? _serviceAddedStreamSub;
  StreamSubscription<BlePeripheralEvent>? _mtuChangedStreamSub;
  StreamSubscription<AvailabilityState>? _availabilityStateStreamSub;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    _attachStreams();
    _setRequestHandlers();
    await _loadConfig();
    await _refreshPeripheralState();
  }

  void _setRequestHandlers() {
    UniversalBlePeripheral.setReadRequestHandlers(
        (deviceId, characteristicId, _, __) {
      _log('Read request: $deviceId $characteristicId');
      return PeripheralReadRequestResult(
        value: Uint8List.fromList(utf8.encode('Hello World')),
      );
    });
    UniversalBlePeripheral.setWriteRequestHandlers(
        (deviceId, characteristicId, _, value) {
      final incoming = value?.toList() ?? <int>[];
      _characteristicIncomingData[characteristicId] = incoming;
      _log('Write request: $deviceId $characteristicId $value');
      setState(() {});
      return PeripheralWriteRequestResult();
    });
  }

  void _attachStreams() {
    _advertisingStateStreamSub = UniversalBlePeripheral.advertisingStateStream
        .listen((BlePeripheralAdvertisingStateChanged event) {
      setState(() => _advertisingState = event.state);
      _log(
          'Advertising state: ${event.state.name} ${event.error ?? ''}'.trim());
    });

    _characteristicSubscriptionStreamSub = UniversalBlePeripheral
        .characteristicSubscriptionStream
        .listen((BlePeripheralCharacteristicSubscriptionChanged event) {
      final set = _subscribedClientsByCharacteristic.putIfAbsent(
        event.characteristicId,
        () => <String>{},
      );
      if (event.isSubscribed) {
        set.add(event.deviceId);
      } else {
        set.remove(event.deviceId);
      }
      _log(
        'Characteristic subscription: ${event.deviceId} ${event.characteristicId} ${event.isSubscribed} ${event.name ?? ''}',
      );
      setState(() {});
    });

    _connectionStateStreamSub = UniversalBlePeripheral.connectionStateStream
        .listen((BlePeripheralConnectionStateChanged event) {
      if (!event.connected) {
        for (final subscribers in _subscribedClientsByCharacteristic.values) {
          subscribers.remove(event.deviceId);
        }
        setState(() {});
      }
      _log('Connection state: ${event.deviceId} ${event.connected}');
    });

    _serviceAddedStreamSub = UniversalBlePeripheral.serviceAddedStream
        .listen((BlePeripheralServiceAdded event) {
      _log('Service added: ${event.serviceId} ${event.error ?? ''}'.trim());
      _refreshServiceStatuses();
    });

    _mtuChangedStreamSub = UniversalBlePeripheral.mtuChangedStream
        .listen((BlePeripheralMtuChanged event) {
      _log('MTU: ${event.deviceId} mtu=${event.mtu}');
    });

    _availabilityStateStreamSub =
        UniversalBle.availabilityStream.listen((availabilityState) {
      _log('Bluetooth availability changed: ${availabilityState.name}');
      _refreshPeripheralState(logResult: false);
    });
  }

  Future<void> _loadConfig() async {
    final config = await GattServerStorage.instance.getById(widget.configId);
    if (!mounted) return;
    setState(() {
      _config = config;
      _isLoadingConfig = false;
    });
  }

  Future<void> _refreshPeripheralState({bool logResult = true}) async {
    setState(() => _isCheckingReadiness = true);
    final supportsPeripheralMode =
        (await UniversalBlePeripheral.getCapabilities()).supportsPeripheralMode;
    final readiness = await UniversalBlePeripheral.getAvailabilityState();
    if (!mounted) return;
    setState(() {
      _supportsPeripheralMode = supportsPeripheralMode;
      _readinessState = readiness;
      _isCheckingReadiness = false;
    });
    if (logResult) {
      _log(
          'Peripheral ready check. supported=$supportsPeripheralMode readiness=${readiness.name}');
    }
    await _refreshServiceStatuses();
  }

  void _log(String text) {
    setState(() {
      _logs.insert(0, text);
    });
  }

  Future<void> _startConfig(GattServerConfig config) async {
    final activeServices = await UniversalBlePeripheral.getServices();
    if (activeServices.isEmpty) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('No Services Added'),
          content: const Text(
            'Add one or more services before starting the server.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    await UniversalBlePeripheral.startAdvertising(
      services: activeServices,
      localName: config.localName,
      manufacturerData: config.manufacturerData,
      platformConfig: PeripheralPlatformConfig(
        android: PeripheralAndroidOptions(
          addManufacturerDataInScanResponse: false,
        ),
      ),
    );
    await _refreshServiceStatuses();
    _log(
      'Started profile "${config.profileName}" with ${activeServices.length} added service(s)',
    );
  }

  Future<void> _stopServer() async {
    await UniversalBlePeripheral.stopAdvertising();
    setState(() => _advertisingState = PeripheralAdvertisingState.idle);
    _log('Stop advertising requested');
  }

  Future<void> _refreshServiceStatuses() async {
    final currentServices = await UniversalBlePeripheral.getServices();
    if (!mounted) return;
    setState(() {
      _addedServiceIds
        ..clear()
        ..addAll(currentServices.map(_normalizeUuid));
    });
  }

  Future<void> _addSingleService(BlePeripheralService service) async {
    try {
      await UniversalBlePeripheral.addService(service);
      _log('Service add requested: ${service.uuid}');
      await _refreshServiceStatuses();
    } catch (error) {
      _log('Failed to add service ${service.uuid}: $error');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Failed to Add Service'),
          content: Text(
            'Could not add service ${service.uuid}.\n\n$error',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _removeSingleService(BlePeripheralService service) async {
    await UniversalBlePeripheral.removeService(service.uuid);
    _log('Service remove requested: ${service.uuid}');
    await _refreshServiceStatuses();
  }

  Future<void> _updateCharacteristicValueDialog(
      BlePeripheralCharacteristic characteristic) async {
    final controller = TextEditingController(
      text: _bytesToHex(_characteristicUpdatedData[characteristic.uuid] ??
          (characteristic.value?.toList() ?? const <int>[])),
    );
    final shouldUpdate = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Update ${characteristic.uuid}'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Value (hex bytes)',
            hintText: '01 FF 0A',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Update'),
          ),
        ],
      ),
    );

    if (shouldUpdate != true) return;
    final bytes = _parseHexBytes(controller.text);
    await UniversalBlePeripheral.updateCharacteristicValue(
      characteristicId: characteristic.uuid,
      value: Uint8List.fromList(bytes),
    );
    _characteristicUpdatedData[characteristic.uuid] = bytes;
    _log(
        'Characteristic updated: ${characteristic.uuid} ${_bytesToHex(bytes)}');
    setState(() {});
  }

  Widget _buildReadinessPlaceholder({
    required IconData icon,
    required String title,
    required String description,
    required Color iconColor,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 52, color: iconColor),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(description, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRuntimeBody() {
    final config = _config;
    if (config == null) {
      return const Center(child: Text('Profile not found.'));
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    config.profileName,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                      '${config.localName} • ${config.services.length} services'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text('Readiness: ${_readinessState?.name ?? 'unknown'}'),
                      const SizedBox(width: 12),
                      Text('Advertising: ${_advertisingState.name}'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _startConfig(config),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start Server'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _stopServer,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                      TextButton.icon(
                        onPressed: _refreshPeripheralState,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh State'),
                      ),
                      TextButton.icon(
                        onPressed: _refreshServiceStatuses,
                        icon: const Icon(Icons.sync),
                        label: const Text('Refresh Services'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Services & Characteristics',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  ...config.services.map(
                    (service) {
                      final isAdded = _addedServiceIds
                          .contains(_normalizeUuid(service.uuid));
                      return ExpansionTile(
                        title: Text(service.uuid),
                        subtitle: Text(
                          isAdded ? 'Status: Added' : 'Status: Not Added',
                          style: TextStyle(
                            color: isAdded
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error,
                          ),
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton.tonal(
                                  onPressed: isAdded
                                      ? null
                                      : () => _addSingleService(service),
                                  child: const Text('Add Service'),
                                ),
                                OutlinedButton(
                                  onPressed: isAdded
                                      ? () => _removeSingleService(service)
                                      : null,
                                  child: const Text('Remove Service'),
                                ),
                              ],
                            ),
                          ),
                          ...service.characteristics.map((characteristic) {
                            final incoming = _characteristicIncomingData[
                                characteristic.uuid];
                            final updated =
                                _characteristicUpdatedData[characteristic.uuid];
                            return ListTile(
                              title: Text(characteristic.uuid),
                              subtitle: Text(
                                'Incoming: ${incoming == null ? '-' : _bytesToHex(incoming)}\n'
                                'Current update value: ${updated == null ? _bytesToHex(characteristic.value?.toList() ?? const <int>[]) : _bytesToHex(updated)}',
                              ),
                              isThreeLine: true,
                              trailing: IconButton(
                                tooltip: 'Update value',
                                onPressed: () =>
                                    _updateCharacteristicValueDialog(
                                        characteristic),
                                icon: const Icon(Icons.edit),
                              ),
                            );
                          }),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_subscribedClientsByCharacteristic.values.any((e) => e.isNotEmpty))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Subscribed Clients',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    ..._subscribedClientsByCharacteristic.entries
                        .where((entry) => entry.value.isNotEmpty)
                        .map((entry) =>
                            Text('${entry.key}: ${entry.value.join(", ")}')),
                  ],
                ),
              ),
            ),
          ),
        const Divider(),
        Expanded(
          child: ListView.builder(
            itemCount: _logs.length,
            itemBuilder: (context, index) => ListTile(
              dense: true,
              title: Text(_logs[index]),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void setState(VoidCallback fn) {
    if (mounted) super.setState(fn);
  }

  @override
  void dispose() {
    _advertisingStateStreamSub?.cancel();
    _characteristicSubscriptionStreamSub?.cancel();
    _connectionStateStreamSub?.cancel();
    _serviceAddedStreamSub?.cancel();
    _mtuChangedStreamSub?.cancel();
    _availabilityStateStreamSub?.cancel();
    UniversalBlePeripheral.setReadRequestHandlers(null);
    UniversalBlePeripheral.setWriteRequestHandlers(null);
    UniversalBlePeripheral.setDescriptorReadRequestHandlers(null);
    UniversalBlePeripheral.setDescriptorWriteRequestHandlers(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget body;
    if (_isLoadingConfig || _isCheckingReadiness || _readinessState == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!_supportsPeripheralMode ||
        _readinessState == PeripheralReadinessState.unsupported) {
      body = _buildReadinessPlaceholder(
        icon: Icons.block,
        title: 'Peripheral Mode Not Supported',
        description:
            'This device does not support acting as a BLE peripheral server.',
        iconColor: colorScheme.outline,
      );
    } else if (_readinessState == PeripheralReadinessState.bluetoothOff) {
      body = _buildReadinessPlaceholder(
        icon: Icons.bluetooth_disabled,
        title: 'Bluetooth is Off',
        description:
            'Turn on Bluetooth to use this GATT server. This screen updates automatically.',
        iconColor: colorScheme.error,
      );
    } else if (_readinessState == PeripheralReadinessState.unauthorized) {
      body = _buildReadinessPlaceholder(
        icon: Icons.lock_outline,
        title: 'Bluetooth Permission Required',
        description: 'Allow Bluetooth permissions in system settings.',
        iconColor: colorScheme.error,
      );
    } else {
      body = _buildRuntimeBody();
    }

    return Scaffold(
      appBar: AppBar(title: Text(_config?.profileName ?? 'Server Runtime')),
      body: body,
    );
  }
}

List<int> _parseHexBytes(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return const [];
  final parts = trimmed.split(RegExp(r'[\s,]+')).where((e) => e.isNotEmpty);
  final values = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part.replaceFirst('0x', ''), radix: 16);
    if (value != null) {
      values.add(value.clamp(0, 255));
    }
  }
  return values;
}

String _bytesToHex(List<int> bytes) => bytes
    .map((value) => value.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

String _normalizeUuid(String uuid) {
  try {
    return BleUuidParser.string(uuid);
  } catch (_) {
    return uuid.toUpperCase();
  }
}
