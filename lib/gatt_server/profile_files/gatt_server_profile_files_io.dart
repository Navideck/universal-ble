import 'dart:io';

Future<String> readUtf8File(String path) => File(path).readAsString();
