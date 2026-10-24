import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The EV Smart Companion logo at any width, keeping its 650 × 480 shape.
class EVLogo extends StatelessWidget {
  const EVLogo({super.key, this.width = 340});

  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height:
        width *
        EVLogoPainter.designSize.height /
        EVLogoPainter.designSize.width,
    child: const CustomPaint(painter: EVLogoPainter()),
  );
}

/// The round logo badge alone, for small square spaces (headers, avatars).
class EVLogoMark extends StatelessWidget {
  const EVLogoMark({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: const CustomPaint(painter: EVLogoPainter(markOnly: true)),
  );
}

/// The supplied logo design. All geometry is in the original 650 × 480
/// design units; [paint] scales it uniformly and centres it, so any canvas
/// size keeps the circle round and the bolt and terminals in proportion.
class EVLogoPainter extends CustomPainter {
  const EVLogoPainter({this.markOnly = false});

  /// Paints only the square around the dark circle instead of the full
  /// design area.
  final bool markOnly;

  static const Size designSize = Size(650, 480);
  static const Rect markRect = Rect.fromLTWH(93, 0, 464, 464);

  @override
  void paint(Canvas canvas, Size size) {
    final source = markOnly ? markRect : Offset.zero & designSize;
    final scale = math.min(
      size.width / source.width,
      size.height / source.height,
    );
    canvas
      ..translate(
        (size.width - source.width * scale) / 2,
        (size.height - source.height * scale) / 2,
      )
      ..scale(scale)
      ..translate(-source.left, -source.top);

    final bgPaint = Paint()..color = const Color(0xFF0B1524);
    canvas.drawCircle(const Offset(325, 232), 232, bgPaint);

    final outline = Paint()
      ..color = const Color(0xFF5B7FA8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final body = Path()
      ..moveTo(180, 370)
      ..cubicTo(120, 320, 108, 260, 108, 200)
      ..cubicTo(108, 110, 200, 62, 325, 62)
      ..cubicTo(450, 62, 542, 110, 542, 200)
      ..cubicTo(542, 260, 530, 320, 468, 370)
      ..lineTo(468, 402)
      ..quadraticBezierTo(468, 420, 450, 420)
      ..lineTo(430, 420)
      ..quadraticBezierTo(412, 420, 412, 402)
      ..lineTo(412, 388)
      ..lineTo(238, 388)
      ..lineTo(238, 402)
      ..quadraticBezierTo(238, 420, 220, 420)
      ..lineTo(200, 420)
      ..quadraticBezierTo(180, 420, 180, 402)
      ..close();
    canvas.drawPath(body, outline);

    canvas.drawCircle(const Offset(200, 332), 22, outline);
    canvas.drawCircle(const Offset(448, 332), 22, outline);

    final bolt = Path()
      ..moveTo(358, 118)
      ..lineTo(273, 247)
      ..lineTo(322, 247)
      ..lineTo(289, 348)
      ..lineTo(388, 217)
      ..lineTo(340, 217)
      ..close();

    final boltPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF3A9AD9), Color(0xFF2DBE8E)],
      ).createShader(const Rect.fromLTWH(273, 118, 115, 230));
    canvas.drawPath(bolt, boltPaint);
  }

  @override
  bool shouldRepaint(covariant EVLogoPainter oldDelegate) =>
      oldDelegate.markOnly != markOnly;
}
