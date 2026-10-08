import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'python_web_resolver.dart';

class PythonSourceInfo {
  PythonSourceInfo.fromJson(Map<String, dynamic> value)
    : id = value['id'] as String,
      name = value['name'] as String,
      filename = value['filename'] as String,
      revision = value['revision'] as String,
      enabled = value['enabled'] == true,
      search = value['search'] == true,
      extend = value['extend'] as String? ?? '';

  final String id, name, filename, revision, extend;
  final bool enabled, search;
}

Future<Map<String, dynamic>> pythonRuntimeConfiguration({
  bool webResolver = true,
}) async {
  String resolver = '';
  if (webResolver &&
      (Platform.isWindows || Platform.isAndroid || Platform.isIOS)) {
    resolver = await PythonWebResolver.instance.start();
  }
  if (Platform.isWindows) {
    final home = path.join(path.dirname(Platform.resolvedExecutable), 'python');
    return {
      'home': home,
      'webResolver': resolver,
      'library': path.join(home, 'python314.dll'),
      'search': [
        path.join(home, 'python314.zip'),
        home,
        path.join(home, 'Lib', 'site-packages'),
      ],
    };
  }
  try {
    final value = await const MethodChannel(
      'duanju/device',
    ).invokeMapMethod<String, dynamic>('pythonRuntime');
    return {...?value, 'webResolver': resolver};
  } on PlatformException {
    return {};
  } on MissingPluginException {
    return {};
  }
}
