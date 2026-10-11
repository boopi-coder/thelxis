import 'dart:io';

import 'package:flutter/services.dart';

/// Widget tests render text with the "Ahem" font (every glyph one em wide),
/// which makes realistic layouts overflow. Loads the Roboto files that ship
/// with the Flutter SDK so tests lay out like a real device. Silently does
/// nothing if the SDK files cannot be found.
Future<void> loadTestFonts() async {
  final env = Platform.environment;
  final root = env['FLUTTER_ROOT'] ?? '${env['HOME']}/development/flutter';
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return;
  final loader = FontLoader('Roboto');
  var any = false;
  for (final name in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    final file = File('${dir.path}/$name');
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
    any = true;
  }
  if (any) await loader.load();
}
