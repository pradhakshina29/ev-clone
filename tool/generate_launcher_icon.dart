// Renders the app logo (lib/widgets/ev_logo.dart) to the PNGs that
// flutter_launcher_icons turns into Android and iOS launcher icons.
//
// Run from the project root, then regenerate the platform icons:
//   flutter test tool/generate_launcher_icon.dart
//   dart run flutter_launcher_icons
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_application_2/widgets/ev_logo.dart';
import 'package:flutter_test/flutter_test.dart';

const _iconSize = 1024.0;
const _background = Color(0xFF0B1524);

Future<void> _writePng(
  String path, {
  required double markFraction,
  Color? background,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  if (background != null) {
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, _iconSize, _iconSize),
      Paint()..color = background,
    );
  }
  final markSize = _iconSize * markFraction;
  final offset = (_iconSize - markSize) / 2;
  canvas.translate(offset, offset);
  const EVLogoPainter(markOnly: true).paint(canvas, Size.square(markSize));
  final image = await recorder.endRecording().toImage(
    _iconSize.toInt(),
    _iconSize.toInt(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  test('generate launcher icon PNGs', () async {
    // iOS and legacy Android: opaque square (iOS rejects transparency).
    await _writePng(
      'assets/icon/app_icon.png',
      markFraction: 0.86,
      background: _background,
    );
    // Android adaptive foreground. flutter_launcher_icons insets it by 16 %
    // per side, so 0.85 here ends up as ~58 % of the 108 dp canvas: the
    // bottom connectors (which reach slightly past the dark circle) stay
    // inside the 66 dp safe zone under every launcher mask.
    await _writePng('assets/icon/app_icon_foreground.png', markFraction: 0.85);
  });
}
