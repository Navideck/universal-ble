import 'gatt_server_profile_files_stub.dart'
    if (dart.library.io) 'gatt_server_profile_files_io.dart' as impl;

Future<String> readUtf8File(String path) => impl.readUtf8File(path);
