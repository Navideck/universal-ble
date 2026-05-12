import 'package:flutter/material.dart';
import 'package:universal_ble_example/home/widgets/drawer.dart';
import 'package:universal_ble_example/data/gatt_server_storage.dart';
import 'package:universal_ble_example/gatt_server/gatt_server_builder_screen.dart';
import 'package:universal_ble_example/models/gatt_server_config.dart';
import 'package:universal_ble_example/gatt_server/gatt_server_runtime_screen.dart';

class GattServer extends StatefulWidget {
  const GattServer({super.key});

  @override
  State<GattServer> createState() => _GattServerState();
}

class _GattServerState extends State<GattServer> {
  List<GattServerConfig> _savedConfigs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSavedConfigs();
  }

  Future<void> _loadSavedConfigs() async {
    final configs = await GattServerStorage.instance.getConfigs();
    if (!mounted) return;
    setState(() {
      _savedConfigs = configs;
      _isLoading = false;
    });
  }

  Future<void> _openGattServerEditor() async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => GattServerEditorScreen(existing: null),
      ),
    );
    _loadSavedConfigs();
  }

  Future<void> _openGattServerBuilder() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const GattServerBuilderScreen(),
      ),
    );
    _loadSavedConfigs();
  }

  void _openRuntimeScreen(GattServerConfig profile) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GattServerRuntimeScreen(configId: profile.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_savedConfigs.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.account_tree_outlined, size: 56),
              const SizedBox(height: 12),
              const Text(
                'No GATT servers added yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                'Create your first GATT server profile to start using it.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _openGattServerEditor,
                icon: const Icon(Icons.add),
                label: const Text('Create GATT Server'),
              ),
            ],
          ),
        ),
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Saved GATT Profiles',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                ElevatedButton.icon(
                  onPressed: _openGattServerBuilder,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Server'),
                )
              ],
            ),
          ),
          Card(
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _savedConfigs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, index) {
                final profile = _savedConfigs[index];
                return ListTile(
                  leading: const Icon(Icons.account_tree_outlined),
                  title: Text(profile.profileName),
                  subtitle: Text(
                      '${profile.localName} • ${profile.services.length} services'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openRuntimeScreen(profile),
                );
              },
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('GATT Server')),
      drawer: const AppDrawer(),
      body: body,
    );
  }
}
