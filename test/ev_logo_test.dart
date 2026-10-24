import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_application_2/screens/login_page.dart';
import 'package:flutter_application_2/screens/signup_page.dart';
import 'package:flutter_application_2/widgets/ev_logo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('logo widgets keep the design proportions at any size', (
    tester,
  ) async {
    for (final width in [48.0, 120.0, 340.0]) {
      await tester.pumpWidget(Center(child: EVLogo(width: width)));
      expect(
        tester.getSize(find.byType(EVLogo)),
        Size(width, width * 480 / 650),
      );
    }
    for (final size in [24.0, 42.0, 72.0]) {
      await tester.pumpWidget(Center(child: EVLogoMark(size: size)));
      expect(tester.getSize(find.byType(EVLogoMark)), Size.square(size));
    }
    expect(tester.takeException(), isNull);
  });

  test('painter scales uniformly and centres the circle in any canvas', () {
    // A wide canvas must not stretch the circle: its centre lands in the
    // middle of the canvas and its radius follows the smaller axis.
    final recorder = ui.PictureRecorder();
    final canvas = _RecordingCanvas(Canvas(recorder));
    const EVLogoPainter(markOnly: true).paint(canvas, const Size(400, 200));
    final background = canvas.circles.first;
    expect(background.center.dx, closeTo(200, 0.01));
    expect(background.center.dy, closeTo(100, 0.01));
    expect(background.radius, closeTo(100, 0.01));
    recorder.endRecording();
  });

  for (final page in <(String, Widget)>[
    ('login', const LoginPage()),
    ('sign-up', const SignUpPage()),
  ]) {
    testWidgets('${page.$1} page shows the logo on a small phone', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(320, 568)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: page.$2));
      expect(find.byType(EVLogoMark), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

/// Applies the painter's transforms to circles so the test can check where
/// they end up on the canvas.
class _RecordingCanvas implements Canvas {
  _RecordingCanvas(this._inner);

  final Canvas _inner;
  final circles = <({Offset center, double radius})>[];
  var _transform = Matrix4.identity();

  @override
  void translate(double dx, double dy) {
    _transform = _transform.multiplied(Matrix4.translationValues(dx, dy, 0));
    _inner.translate(dx, dy);
  }

  @override
  void scale(double sx, [double? sy]) {
    _transform = _transform.multiplied(
      Matrix4.diagonal3Values(sx, sy ?? sx, 1),
    );
    _inner.scale(sx, sy);
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    final center = MatrixUtils.transformPoint(_transform, c);
    circles.add((center: center, radius: radius * _transform.storage[0]));
    _inner.drawCircle(c, radius, paint);
  }

  @override
  void drawPath(Path path, Paint paint) => _inner.drawPath(path, paint);

  // The painter uses no other Canvas members.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
