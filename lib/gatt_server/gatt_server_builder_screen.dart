import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:universal_ble_example/data/company_identifier_service.dart';
import 'package:universal_ble_example/data/gatt_server_storage.dart';
import 'package:universal_ble_example/models/gatt_server_config.dart';

class GattServerBuilderScreen extends StatefulWidget {
  const GattServerBuilderScreen({super.key});

  @override
  State<GattServerBuilderScreen> createState() =>
      _GattServerBuilderScreenState();
}

class _GattServerBuilderScreenState extends State<GattServerBuilderScreen> {
  final _storage = GattServerStorage.instance;
  List<GattServerConfig> _configs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    final configs = await _storage.getConfigs();
    if (!mounted) return;
    setState(() {
      _configs = configs;
      _isLoading = false;
    });
  }

  Future<void> _openEditor({GattServerConfig? existing}) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => GattServerEditorScreen(existing: existing),
      ),
    );
    if (saved == true) {
      await _loadConfigs();
    }
  }

  Future<void> _deleteConfig(GattServerConfig config) async {
    await _storage.deleteConfig(config.id);
    await _loadConfigs();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gatt Server Profiles'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isLoading ? null : () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('Create Profile'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _configs.isEmpty
              ? const Center(
                  child: Text(
                    'No saved GATT server profiles yet.\nCreate one to quickly start advertising later.',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _configs.length,
                  itemBuilder: (_, index) {
                    final config = _configs[index];
                    return Card(
                      child: ListTile(
                        title: Text(config.profileName),
                        subtitle: Text(
                          'Name: ${config.localName} | Services: ${config.services.length}',
                        ),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              tooltip: 'Edit',
                              onPressed: () => _openEditor(existing: config),
                              icon: const Icon(Icons.edit),
                            ),
                            IconButton(
                              tooltip: 'Delete',
                              onPressed: () => _deleteConfig(config),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class GattServerEditorScreen extends StatefulWidget {
  final GattServerConfig? existing;
  const GattServerEditorScreen({super.key, this.existing});

  @override
  State<GattServerEditorScreen> createState() => _GattServerEditorScreenState();
}

class _GattServerEditorScreenState extends State<GattServerEditorScreen> {
  final _storage = GattServerStorage.instance;
  final _profileNameController = TextEditingController();
  final _localNameController = TextEditingController();
  ManufacturerData? _manufacturerData;
  final List<BlePeripheralService> _services = [];

  @override
  void initState() {
    super.initState();
    CompanyIdentifierService.instance.load();
    final existing = widget.existing;
    if (existing != null) {
      _profileNameController.text = existing.profileName;
      _localNameController.text = existing.localName;
      _manufacturerData = existing.manufacturerData;
      _services.addAll(existing.services);
    } else {
      _localNameController.text = 'UniBle';
    }
  }

  @override
  void dispose() {
    _profileNameController.dispose();
    _localNameController.dispose();
    super.dispose();
  }

  Future<void> _addService() async {
    final service = await _showServiceDialog();
    if (service == null) return;
    setState(() {
      _services.add(service);
    });
  }

  Future<void> _addCharacteristic(int serviceIndex) async {
    final characteristic = await _showCharacteristicDialog();
    if (characteristic == null) return;
    setState(() {
      final service = _services[serviceIndex];
      _services[serviceIndex] = BlePeripheralService(
        uuid: service.uuid,
        primary: service.primary,
        characteristics: [...service.characteristics, characteristic],
      );
    });
  }

  Future<void> _addDescriptor(int serviceIndex, int characteristicIndex) async {
    final descriptor = await _showDescriptorDialog();
    if (descriptor == null) return;
    setState(() {
      final service = _services[serviceIndex];
      final characteristic = service.characteristics[characteristicIndex];
      final updatedCharacteristic = BlePeripheralCharacteristic(
        uuid: characteristic.uuid,
        properties: [...characteristic.properties],
        permissions: [...characteristic.permissions],
        value: characteristic.value,
        descriptors: [...characteristic.descriptors, descriptor],
      );
      final updatedCharacteristics = [...service.characteristics];
      updatedCharacteristics[characteristicIndex] = updatedCharacteristic;
      _services[serviceIndex] = BlePeripheralService(
        uuid: service.uuid,
        primary: service.primary,
        characteristics: updatedCharacteristics,
      );
    });
  }

  Future<BlePeripheralService?> _showServiceDialog() async {
    final uuidController = TextEditingController();
    bool primary = true;
    return showDialog<BlePeripheralService>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          return AlertDialog(
            title: const Text('Add Service'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: uuidController,
                  decoration: const InputDecoration(labelText: 'Service UUID'),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: primary,
                  onChanged: (value) => setStateDialog(() => primary = value),
                  title: const Text('Primary'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (uuidController.text.trim().isEmpty) return;
                  try {
                    final normalizedUuid =
                        BleUuidParser.string(uuidController.text.trim());
                    Navigator.pop(
                      context,
                      BlePeripheralService(
                        uuid: normalizedUuid,
                        primary: primary,
                        characteristics: const [],
                      ),
                    );
                  } on FormatException {
                    _showSnackbar('Invalid Service UUID');
                  }
                },
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<BlePeripheralCharacteristic?> _showCharacteristicDialog() async {
    final uuidController = TextEditingController();
    final initialValueController = TextEditingController();
    final selectedProperties = <CharacteristicProperty>{};
    final selectedPermissions = <PeripheralAttributePermission>{};

    return showDialog<BlePeripheralCharacteristic>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          return AlertDialog(
            title: const Text('Add Characteristic'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: uuidController,
                      decoration: const InputDecoration(
                        labelText: 'Characteristic UUID',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Properties',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Wrap(
                      spacing: 6,
                      children: CharacteristicProperty.values
                          .map(
                            (property) => FilterChip(
                              selected: selectedProperties.contains(property),
                              label: Text(property.name),
                              onSelected: (selected) {
                                setStateDialog(() {
                                  if (selected) {
                                    selectedProperties.add(property);
                                  } else {
                                    selectedProperties.remove(property);
                                  }
                                });
                              },
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Permissions',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Wrap(
                      spacing: 6,
                      children: PeripheralAttributePermission.values
                          .map(
                            (permission) => FilterChip(
                              selected:
                                  selectedPermissions.contains(permission),
                              label: Text(permission.name),
                              onSelected: (selected) {
                                setStateDialog(() {
                                  if (selected) {
                                    selectedPermissions.add(permission);
                                  } else {
                                    selectedPermissions.remove(permission);
                                  }
                                });
                              },
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: initialValueController,
                      decoration: const InputDecoration(
                        labelText: 'Initial Value (hex bytes, optional)',
                        hintText: '01 FF 0A',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (uuidController.text.trim().isEmpty) return;
                  try {
                    final normalizedUuid =
                        BleUuidParser.string(uuidController.text.trim());
                    final initialBytes =
                        _parseHexBytes(initialValueController.text);
                    if (initialBytes.isNotEmpty) {
                      const writeLike = {
                        CharacteristicProperty.write,
                        CharacteristicProperty.writeWithoutResponse,
                        CharacteristicProperty.authenticatedSignedWrites,
                      };
                      if (selectedProperties.any(writeLike.contains)) {
                        _showSnackbar(
                          'On Apple platforms, an initial value makes the '
                          'characteristic read-only. Clear the initial value or '
                          'remove write-related properties.',
                        );
                        return;
                      }
                    }
                    Navigator.pop(
                      context,
                      BlePeripheralCharacteristic(
                        uuid: normalizedUuid,
                        properties: selectedProperties.toList(),
                        permissions: selectedPermissions.toList(),
                        value: initialBytes.isEmpty
                            ? null
                            : Uint8List.fromList(initialBytes),
                      ),
                    );
                  } on FormatException {
                    _showSnackbar('Invalid Characteristic UUID');
                  }
                },
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<BlePeripheralDescriptor?> _showDescriptorDialog() async {
    final uuidController = TextEditingController();
    final initialValueController = TextEditingController();
    final selectedPermissions = <PeripheralAttributePermission>{};
    return showDialog<BlePeripheralDescriptor>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          return AlertDialog(
            title: const Text('Add Descriptor'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: uuidController,
                      decoration: const InputDecoration(
                        labelText: 'Descriptor UUID',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Permissions',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Wrap(
                      spacing: 6,
                      children: PeripheralAttributePermission.values
                          .map(
                            (permission) => FilterChip(
                              selected:
                                  selectedPermissions.contains(permission),
                              label: Text(permission.name),
                              onSelected: (selected) {
                                setStateDialog(() {
                                  if (selected) {
                                    selectedPermissions.add(permission);
                                  } else {
                                    selectedPermissions.remove(permission);
                                  }
                                });
                              },
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: initialValueController,
                      decoration: const InputDecoration(
                        labelText: 'Initial Value (hex bytes, optional)',
                        hintText: '00 01',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (uuidController.text.trim().isEmpty) return;
                  try {
                    final normalizedUuid =
                        BleUuidParser.string(uuidController.text.trim());
                    final initialBytes =
                        _parseHexBytes(initialValueController.text);
                    Navigator.pop(
                      context,
                      BlePeripheralDescriptor(
                        uuid: normalizedUuid,
                        permissions: selectedPermissions.toList(),
                        value: initialBytes.isEmpty
                            ? null
                            : Uint8List.fromList(initialBytes),
                      ),
                    );
                  } on FormatException {
                    _showSnackbar('Invalid Descriptor UUID');
                  }
                },
                child: const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _saveProfile() async {
    if (_profileNameController.text.trim().isEmpty) return;
    final config = GattServerConfig(
      id: widget.existing?.id ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      profileName: _profileNameController.text.trim(),
      localName: _localNameController.text.trim().isEmpty
          ? 'UniBle'
          : _localNameController.text.trim(),
      manufacturerData: _manufacturerData,
      services: _services,
    );
    await _storage.saveConfig(config);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _openManufacturerDataDialog() async {
    final applied = await showDialog<_ManufacturerDataApply?>(
      context: context,
      builder: (context) => _ManufacturerDataEditorDialog(
        initial: _manufacturerData,
      ),
    );
    if (!mounted || applied == null) return;
    setState(() => _manufacturerData = applied.value);
  }

  void _clearManufacturerData() {
    setState(() => _manufacturerData = null);
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null
            ? 'Create GATT Profile'
            : 'Edit GATT Profile'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _profileNameController,
            decoration: const InputDecoration(labelText: 'Profile Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _localNameController,
            decoration:
                const InputDecoration(labelText: 'Advertised Local Name'),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.memory),
              title: const Text('Manufacturer data'),
              subtitle: Text(
                _manufacturerData == null
                    ? 'Not set'
                    : '${_manufacturerData!.companyIdRadix16} · payload ${_bytesToHex(_manufacturerData!.payload)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: _openManufacturerDataDialog,
                    child: Text(_manufacturerData == null ? 'Add' : 'Edit'),
                  ),
                  if (_manufacturerData != null)
                    TextButton(
                      onPressed: _clearManufacturerData,
                      child: const Text('Clear'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Text('Services', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _addService,
                icon: const Icon(Icons.add),
                label: const Text('Add Service'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_services.isEmpty)
            const Text('No services yet. Add one or more services.'),
          ...List.generate(_services.length, (serviceIndex) {
            final service = _services[serviceIndex];
            return Card(
              child: ExpansionTile(
                title: Text(service.uuid),
                subtitle: Text(
                  'Primary: ${service.primary} | Characteristics: ${service.characteristics.length}',
                ),
                children: [
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => _addCharacteristic(serviceIndex),
                            icon: const Icon(Icons.add),
                            label: const Text('Characteristic'),
                          ),
                          TextButton(
                            onPressed: () {
                              setState(() => _services.removeAt(serviceIndex));
                            },
                            child: const Text('Remove Service'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ...List.generate(service.characteristics.length, (charIndex) {
                    final characteristic = service.characteristics[charIndex];
                    return ListTile(
                      title: Text(characteristic.uuid),
                      subtitle: Text(
                        'Properties: ${characteristic.properties.map((e) => e.name).join(", ")}\nPermissions: ${characteristic.permissions.map((e) => e.name).join(", ")}\nDescriptors: ${characteristic.descriptors.length}',
                      ),
                      isThreeLine: true,
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          IconButton(
                            tooltip: 'Add Descriptor',
                            onPressed: () =>
                                _addDescriptor(serviceIndex, charIndex),
                            icon: const Icon(Icons.add_link),
                          ),
                          IconButton(
                            tooltip: 'Remove Characteristic',
                            onPressed: () {
                              setState(() {
                                final updated = [...service.characteristics];
                                updated.removeAt(charIndex);
                                _services[serviceIndex] = BlePeripheralService(
                                  uuid: service.uuid,
                                  primary: service.primary,
                                  characteristics: updated,
                                );
                              });
                            },
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            );
          }),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _saveProfile,
            icon: const Icon(Icons.save),
            label: const Text('Save GATT Server Profile'),
          ),
        ),
      ),
    );
  }
}

/// Dialog result: [value] is `null` to clear manufacturer data from the profile.
class _ManufacturerDataApply {
  final ManufacturerData? value;
  const _ManufacturerDataApply(this.value);
}

class _ManufacturerDataEditorDialog extends StatefulWidget {
  final ManufacturerData? initial;

  const _ManufacturerDataEditorDialog({this.initial});

  @override
  State<_ManufacturerDataEditorDialog> createState() =>
      _ManufacturerDataEditorDialogState();
}

class _ManufacturerDataEditorDialogState
    extends State<_ManufacturerDataEditorDialog> {
  late final TextEditingController _companyController;
  late final TextEditingController _payloadController;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _companyController = TextEditingController(
      text: initial?.companyIdRadix16 ?? '',
    );
    _payloadController = TextEditingController(
      text: initial == null ? '' : initial.payload.map(_toHex).join(' '),
    );
    _companyController.addListener(() => setState(() {}));
    _payloadController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _companyController.dispose();
    _payloadController.dispose();
    super.dispose();
  }

  void _showDialogSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _save() {
    final companyInput = _companyController.text.trim();
    final payloadStr = _payloadController.text;
    if (companyInput.isEmpty && payloadStr.trim().isEmpty) {
      Navigator.pop(context, const _ManufacturerDataApply(null));
      return;
    }
    if (companyInput.isEmpty) {
      _showDialogSnack('Company ID is required when payload is set.');
      return;
    }
    final companyId =
        CompanyIdentifierService.instance.parseCompanyIdentifier(companyInput);
    if (companyId == null) {
      _showDialogSnack('Could not parse company identifier.');
      return;
    }
    final payloadBytes = _parseHexBytesStrict(payloadStr);
    if (payloadBytes == null) {
      _showDialogSnack(
          'Invalid hex in manufacturer payload (use 00–FF bytes).');
      return;
    }
    final md = ManufacturerData(
      companyId,
      Uint8List.fromList(payloadBytes),
    );
    try {
      final verified = ManufacturerData.fromData(md.toUint8List());
      if (verified != md) {
        _showDialogSnack(
          'Internal verification failed: encoded bytes do not round-trip.',
        );
        return;
      }
    } on FormatException catch (e) {
      _showDialogSnack('Verification failed: $e');
      return;
    }
    Navigator.pop(context, _ManufacturerDataApply(md));
  }

  Widget _buildPreview(BuildContext context) {
    final theme = Theme.of(context);
    final companyInput = _companyController.text.trim();
    final payloadStr = _payloadController.text;
    if (companyInput.isEmpty && payloadStr.trim().isEmpty) {
      return Text(
        'Leave both fields empty and save to omit manufacturer data.',
        style: theme.textTheme.bodySmall,
      );
    }
    if (companyInput.isEmpty) {
      return Text(
        'Company ID is required when a payload is set.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final companyId =
        CompanyIdentifierService.instance.parseCompanyIdentifier(companyInput);
    if (companyId == null) {
      return Text(
        'Could not parse company identifier.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final payloadBytes = _parseHexBytesStrict(payloadStr);
    if (payloadStr.trim().isNotEmpty && payloadBytes == null) {
      return Text(
        'Invalid hex in payload (each byte must be 00–FF, space-separated).',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final md = ManufacturerData(
      companyId,
      Uint8List.fromList(payloadBytes ?? const []),
    );
    try {
      final verified = ManufacturerData.fromData(md.toUint8List());
      if (verified != md) {
        return Text(
          'Verification failed: encoded bytes do not match decode.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        );
      }
    } on FormatException catch (e) {
      return Text(
        'Verification failed: $e',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final companyName =
        CompanyIdentifierService.instance.getCompanyName(md.companyId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Preview (verified)',
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 6),
        Text('Company: ${md.companyIdRadix16}'),
        if (companyName != null && companyName.isNotEmpty)
          Text('Name: $companyName'),
        Text('Payload (${md.payload.length} B): ${_bytesToHex(md.payload)}'),
        Text(
          'Advertising bytes (${md.toUint8List().length} B): '
          '${_bytesToHex(md.toUint8List())}',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Manufacturer data'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _companyController,
                decoration: const InputDecoration(
                  labelText: 'Company ID or name',
                  hintText: '0x004C or Apple, Inc.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _payloadController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Payload (hex bytes, optional)',
                  hintText: '01 02 0A',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _buildPreview(context),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, const _ManufacturerDataApply(null)),
          child: const Text('Clear'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

List<int>? _parseHexBytesStrict(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return const [];
  final parts = trimmed.split(RegExp(r'[\s,]+')).where((e) => e.isNotEmpty);
  final values = <int>[];
  for (final part in parts) {
    final cleaned = part.replaceFirst(RegExp(r'^0x', caseSensitive: false), '');
    final value = int.tryParse(cleaned, radix: 16);
    if (value == null || value < 0 || value > 255) {
      return null;
    }
    values.add(value);
  }
  return values;
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

String _toHex(int value) =>
    value.toRadixString(16).padLeft(2, '0').toUpperCase();

String _bytesToHex(Iterable<int> bytes) => bytes.map(_toHex).join(' ');
