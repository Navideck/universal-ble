import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:universal_ble_example/data/gatt_server_storage.dart';
import 'package:universal_ble_example/models/gatt_server_config.dart';
import 'package:universal_ble_example/peripheral_details/widgets/result_widget.dart';
import 'package:universal_ble_example/widgets/responsive_view.dart';

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
  final ScrollController _logsScrollController = ScrollController();

  /// Normalized characteristic UUID → central deviceId → display label (name or id).
  final Map<String, Map<String, String>> _subscribersByCharacteristic = {};
  final Set<String> _addedServiceIds = <String>{};
  final Map<String, List<int>> _characteristicIncomingData =
      <String, List<int>>{};
  final Map<String, List<int>> _characteristicUpdatedData =
      <String, List<int>>{};
  final Map<String, TextEditingController> _hexDraftByCharacteristic = {};

  GattServerConfig? _config;
  bool _isLoadingConfig = true;
  bool _bulkServiceMutation = false;
  bool _supportsPeripheralMode = false;
  bool _isCheckingReadiness = true;
  PeripheralReadinessState? _readinessState;
  PeripheralAdvertisingState _advertisingState =
      PeripheralAdvertisingState.idle;

  bool get _advertisingIsActive =>
      _advertisingState == PeripheralAdvertisingState.advertising;

  bool get _advertisingTransitioning =>
      _advertisingState == PeripheralAdvertisingState.starting ||
      _advertisingState == PeripheralAdvertisingState.stopping;

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
    await _loadConfig();
    _setRequestHandlers();
    await _refreshPeripheralState();
  }

  /// Value returned for GATT reads: last notify/indicate payload, else profile initial value.
  Uint8List _readPayloadForCharacteristic(String characteristicId) {
    final norm = _normalizeUuid(characteristicId);
    for (final e in _characteristicUpdatedData.entries) {
      if (_normalizeUuid(e.key) == norm) {
        return Uint8List.fromList(e.value);
      }
    }
    final config = _config;
    if (config != null) {
      for (final service in config.services) {
        for (final c in service.characteristics) {
          if (_normalizeUuid(c.uuid) == norm) {
            final bytes = c.value?.toList() ?? const <int>[];
            return Uint8List.fromList(bytes);
          }
        }
      }
    }
    return Uint8List(0);
  }

  void _setRequestHandlers() {
    UniversalBlePeripheral.setReadRequestHandlers(
        (deviceId, characteristicId, _, __) {
      _log('Read request: $deviceId $characteristicId');
      return PeripheralReadRequestResult(
        value: _readPayloadForCharacteristic(characteristicId),
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
      final charKey = _normalizeUuid(event.characteristicId);
      final clients = _subscribersByCharacteristic.putIfAbsent(
        charKey,
        () => <String, String>{},
      );
      if (event.isSubscribed) {
        final label = (event.name != null && event.name!.trim().isNotEmpty)
            ? event.name!.trim()
            : event.deviceId;
        clients[event.deviceId] = label;
      } else {
        clients.remove(event.deviceId);
        if (clients.isEmpty) {
          _subscribersByCharacteristic.remove(charKey);
        }
      }
      _log(
        'Characteristic subscription: ${event.deviceId} ${event.characteristicId} ${event.isSubscribed} ${event.name ?? ''}',
      );
      setState(() {});
    });

    _connectionStateStreamSub = UniversalBlePeripheral.connectionStateStream
        .listen((BlePeripheralConnectionStateChanged event) {
      if (!event.connected) {
        for (final clients in _subscribersByCharacteristic.values) {
          clients.remove(event.deviceId);
        }
        _subscribersByCharacteristic
            .removeWhere((_, clients) => clients.isEmpty);
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
      _logs.add(text);
    });
  }

  Widget _buildResultWidget({required bool scrollable}) {
    return ResultWidget(
      results: _logs,
      scrollController: _logsScrollController,
      scrollable: scrollable,
      onCopyTap: () async {
        if (_logs.isEmpty) return;
        final logsText = _logs.join('\n');
        await Clipboard.setData(ClipboardData(text: logsText));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All logs copied to clipboard')),
        );
      },
      onClearTap: (int? index) {
        setState(() {
          if (index != null) {
            _logs.removeAt(index);
          } else {
            _logs.clear();
          }
        });
      },
    );
  }

  Future<void> _startConfig(GattServerConfig config) async {
    final failedAdds =
        await _addMissingProfileServices(config, logVerb: 'Start');
    if (!mounted) return;

    if (failedAdds.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Some services failed to add'),
          content: SingleChildScrollView(
            child: Text(
              failedAdds.entries
                  .map((e) => '${e.key}\n${e.value}')
                  .join('\n\n'),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (!mounted) return;
    }

    final activeServices = await UniversalBlePeripheral.getServices();
    if (activeServices.isEmpty) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Cannot Start Server'),
          content: const Text(
            'No GATT services are on the peripheral stack. '
            'Add services from this profile or fix errors, then try again.',
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

  /// Adds each profile service that is not already on the GATT stack.
  /// Returns service UUID → error for failures.
  Future<Map<String, String>> _addMissingProfileServices(
    GattServerConfig config, {
    required String logVerb,
  }) async {
    final failed = <String, String>{};
    for (final service in config.services) {
      if (!mounted) break;
      final onStack = (await UniversalBlePeripheral.getServices())
          .map(_normalizeUuid)
          .toSet();
      final id = _normalizeUuid(service.uuid);
      if (onStack.contains(id)) continue;
      try {
        await UniversalBlePeripheral.addService(service);
        _log('$logVerb: added ${service.uuid}');
      } catch (e) {
        failed[service.uuid] = e.toString();
        _log('$logVerb: failed to add ${service.uuid}: $e');
      }
    }
    await _refreshServiceStatuses();
    return failed;
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

  Future<void> _addAllServicesFromProfile(GattServerConfig config) async {
    if (config.services.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This profile has no services to add.')),
      );
      return;
    }
    setState(() => _bulkServiceMutation = true);
    try {
      final failed =
          await _addMissingProfileServices(config, logVerb: 'Add all');
      if (!mounted) return;
      if (failed.isEmpty) {
        _log(
            'Add all finished (${config.services.length} profile service(s) processed)');
      } else {
        _log('Add all finished with ${failed.length} failure(s)');
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Some services failed to add'),
            content: SingleChildScrollView(
              child: Text(
                failed.entries.map((e) => '${e.key}\n${e.value}').join('\n\n'),
              ),
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
    } finally {
      if (mounted) setState(() => _bulkServiceMutation = false);
    }
  }

  Future<void> _confirmRemoveAllServices() async {
    final ids = await UniversalBlePeripheral.getServices();
    if (ids.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No services are on the peripheral stack.')),
      );
      return;
    }
    final advertising = _advertisingIsActive;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove all services?'),
        content: Text(
          advertising
              ? 'This removes ${ids.length} service(s) from the GATT stack and '
                  'stops advertising first.'
              : 'This removes ${ids.length} service(s) from the GATT stack.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _bulkServiceMutation = true);
    try {
      if (advertising) {
        await UniversalBlePeripheral.stopAdvertising();
        if (mounted) {
          setState(() => _advertisingState = PeripheralAdvertisingState.idle);
        }
        _log('Stopped advertising before removing all services');
      }
      final toRemove =
          List<String>.from(await UniversalBlePeripheral.getServices());
      for (final id in toRemove) {
        if (!mounted) break;
        try {
          await UniversalBlePeripheral.removeService(id);
          _log('Removed service $id');
        } catch (e) {
          _log('Failed to remove $id: $e');
        }
      }
      await _refreshServiceStatuses();
      _log('Remove all finished (${toRemove.length} service(s))');
    } finally {
      if (mounted) setState(() => _bulkServiceMutation = false);
    }
  }

  bool _characteristicSupportsNotifyOrIndicate(BlePeripheralCharacteristic c) {
    return c.properties.contains(CharacteristicProperty.notify) ||
        c.properties.contains(CharacteristicProperty.indicate);
  }

  String _subscriberLine(String characteristicUuid) {
    final key = _normalizeUuid(characteristicUuid);
    final map = _subscribersByCharacteristic[key];
    if (map == null || map.isEmpty) {
      return 'Subscribers: 0';
    }
    final parts = map.values.toList();
    return 'Subscribers: ${map.length} (${parts.join(', ')})';
  }

  TextEditingController _hexDraftFor(BlePeripheralCharacteristic c) {
    final key = _normalizeUuid(c.uuid);
    return _hexDraftByCharacteristic.putIfAbsent(key, () {
      final initialBytes = _characteristicUpdatedData[c.uuid] ??
          c.value?.toList() ??
          const <int>[];
      return TextEditingController(text: _bytesToHex(initialBytes));
    });
  }

  Future<void> _pushCharacteristicValue(
      BlePeripheralCharacteristic characteristic) async {
    if (!_characteristicSupportsNotifyOrIndicate(characteristic)) return;
    final key = _normalizeUuid(characteristic.uuid);
    final controller = _hexDraftByCharacteristic[key];
    if (controller == null) return;
    final bytes = _parseHexBytes(controller.text);
    try {
      await UniversalBlePeripheral.updateCharacteristicValue(
        characteristicId: characteristic.uuid,
        value: Uint8List.fromList(bytes),
      );
      _characteristicUpdatedData[characteristic.uuid] = bytes;
      controller.text = _bytesToHex(bytes);
      _log(
        'Characteristic updated: ${characteristic.uuid} ${_bytesToHex(bytes)}',
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update failed: $e')),
      );
    }
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

  Widget _buildRuntimeMainContent(GattServerConfig config) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                        onPressed: _advertisingTransitioning
                            ? null
                            : (_advertisingIsActive
                                ? _stopServer
                                : () => _startConfig(config)),
                        icon: Icon(
                          _advertisingIsActive ? Icons.stop : Icons.play_arrow,
                        ),
                        label: Text(
                          _advertisingTransitioning
                              ? (_advertisingState ==
                                      PeripheralAdvertisingState.starting
                                  ? 'Starting…'
                                  : 'Stopping…')
                              : (_advertisingIsActive
                                  ? 'Stop Server'
                                  : 'Start Server'),
                        ),
                        style: _advertisingIsActive
                            ? FilledButton.styleFrom(
                                backgroundColor:
                                    Theme.of(context).colorScheme.error,
                                foregroundColor:
                                    Theme.of(context).colorScheme.onError,
                              )
                            : null,
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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Expanded(
                        child: Text(
                          'Services & Characteristics',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.end,
                        children: [
                          FilledButton.tonal(
                            onPressed: _bulkServiceMutation
                                ? null
                                : () => _addAllServicesFromProfile(config),
                            child: const Text('Add all'),
                          ),
                          OutlinedButton(
                            onPressed: _bulkServiceMutation
                                ? null
                                : _confirmRemoveAllServices,
                            child: const Text('Remove all'),
                          ),
                        ],
                      ),
                    ],
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
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Row(
                              spacing: 8,
                              children: [
                                FilledButton.tonal(
                                  onPressed: _bulkServiceMutation || isAdded
                                      ? null
                                      : () => _addSingleService(service),
                                  child: const Text('Add Service'),
                                ),
                                OutlinedButton(
                                  onPressed: _bulkServiceMutation || !isAdded
                                      ? null
                                      : () => _removeSingleService(service),
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
                            final theme = Theme.of(context);
                            final colorScheme = theme.colorScheme;
                            final notifyOrIndicate =
                                _characteristicSupportsNotifyOrIndicate(
                                    characteristic);
                            final canPush = isAdded &&
                                notifyOrIndicate &&
                                !_bulkServiceMutation;
                            final draft = _hexDraftFor(characteristic);
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 12, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    characteristic.uuid,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Properties: ${characteristic.properties.map((e) => e.name).join(", ")}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  Text(
                                    'Incoming (write): ${incoming == null ? '—' : _bytesToHex(incoming)}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  Text(
                                    'Current value: ${updated == null ? _bytesToHex(characteristic.value?.toList() ?? const <int>[]) : _bytesToHex(updated)}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 4),
                                    child: Text(
                                      _subscriberLine(characteristic.uuid),
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                  if (notifyOrIndicate) ...[
                                    const SizedBox(height: 8),
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: draft,
                                            enabled: isAdded &&
                                                !_bulkServiceMutation,
                                            decoration: const InputDecoration(
                                              labelText:
                                                  'Notify / indicate value (hex)',
                                              hintText: '01 FF 0A',
                                              isDense: true,
                                              border: OutlineInputBorder(),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton.filled(
                                          tooltip:
                                              'Send value to subscribed centrals',
                                          onPressed: canPush
                                              ? () => _pushCharacteristicValue(
                                                    characteristic,
                                                  )
                                              : null,
                                          icon: const Icon(Icons.publish),
                                        ),
                                      ],
                                    ),
                                  ] else
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(
                                        'Value push requires notify or indicate on this characteristic.',
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurface
                                              .withValues(alpha: 0.65),
                                        ),
                                      ),
                                    ),
                                ],
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
        if (_subscribersByCharacteristic.values.any((e) => e.isNotEmpty))
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
                    ..._subscribersByCharacteristic.entries
                        .where((entry) => entry.value.isNotEmpty)
                        .map(
                          (entry) => Text(
                            '${entry.key}: ${entry.value.length} — '
                            '${entry.value.values.join(', ')}',
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRuntimeBody() {
    final config = _config;
    if (config == null) {
      return const Center(child: Text('Profile not found.'));
    }

    return ResponsiveView(
      builder: (_, DeviceType deviceType) {
        final main = _buildRuntimeMainContent(config);
        if (deviceType == DeviceType.desktop) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 2,
                child: SingleChildScrollView(child: main),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 1,
                child: _buildResultWidget(scrollable: true),
              ),
            ],
          );
        }
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              main,
              const Divider(),
              _buildResultWidget(scrollable: false),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
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
    for (final c in _hexDraftByCharacteristic.values) {
      c.dispose();
    }
    _hexDraftByCharacteristic.clear();
    _logsScrollController.dispose();
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
