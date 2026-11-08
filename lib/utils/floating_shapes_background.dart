import 'package:flutter/material.dart';

import 'dart:math' as math;

/// Represents an individual floating geometric shape within the background.
class FloatingShape {
  double x, y;
  double speedX, speedY;
  double size;
  double rotation;
  double rotationSpeed;

  /// The type of shape (0: Circle, 1: Rounded Rectangle, 2: Triangle).
  int type;

  /// The color and opacity of the shape.
  final Color color;

  FloatingShape({
    required this.x,
    required this.y,
    required this.speedX,
    required this.speedY,
    required this.size,
    required this.rotation,
    required this.rotationSpeed,
    required this.type,
    required this.color,
  });

  /// Updates the shape's position and rotation, handling screen boundary wrapping.
  void update(Size bounds) {
    if (bounds.width == 0 || bounds.height == 0) return;
    x += speedX;
    y += speedY;
    rotation += rotationSpeed;

    // Wrap around horizontal boundaries.
    if (x < -size) x = bounds.width + size;
    if (x > bounds.width + size) x = -size;

    // Wrap around vertical boundaries.
    if (y < -size) y = bounds.height + size;
    if (y > bounds.height + size) y = -size;
  }
}

/// A widget that renders a dynamic, animated background consisting of floating geometric shapes.
class FloatingShapesBackground extends StatefulWidget {
  /// The solid background color behind the shapes.
  final Color baseColor;

  /// Global multiplier for the movement and rotation speed of all shapes.
  final double speedMultiplier;

  const FloatingShapesBackground({
    super.key,
    required this.baseColor,
    this.speedMultiplier = 1.0,
  });

  @override
  State<FloatingShapesBackground> createState() =>
      _FloatingShapesBackgroundState();
}

class _FloatingShapesBackgroundState extends State<FloatingShapesBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<FloatingShape> _shapes = [];
  final math.Random _random = math.Random();

  @override
  void initState() {
    super.initState();
    _initShapes();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
  }

  /// Initializes the collection of floating shapes with randomized properties.
  void _initShapes() {
    for (int i = 0; i < 20; i++) {
      _shapes.add(
        FloatingShape(
          x: _random.nextDouble() * 500,
          y: _random.nextDouble() * 100,
          speedX: (_random.nextDouble() - 0.5) * 1.5 * widget.speedMultiplier,
          speedY: (_random.nextDouble() - 0.5) * 1.5 * widget.speedMultiplier,
          size: _random.nextDouble() * 25 + 10,
          rotation: _random.nextDouble() * math.pi * 2,
          rotationSpeed:
              (_random.nextDouble() - 0.5) * 0.05 * widget.speedMultiplier,
          type: _random.nextInt(3),
          color: Colors.white.withValues(
            alpha: _random.nextDouble() * 0.1 + 0.05,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: widget.baseColor,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(painter: _ShapesPainter(_shapes));
        },
      ),
    );
  }
}

/// A custom painter responsible for rendering the list of [FloatingShape]s.
class _ShapesPainter extends CustomPainter {
  final List<FloatingShape> shapes;

  _ShapesPainter(this.shapes);

  @override
  void paint(Canvas canvas, Size size) {
    for (final shape in shapes) {
      shape.update(size);

      final paint = Paint()
        ..color = shape.color
        ..style = PaintingStyle.fill;

      canvas.save();
      canvas.translate(shape.x, shape.y);
      canvas.rotate(shape.rotation);

      if (shape.type == 0) {
        // Draw Circle.
        canvas.drawCircle(Offset.zero, shape.size / 2, paint);
      } else if (shape.type == 1) {
        // Draw Rounded Rectangle.
        final rect = Rect.fromCenter(
          center: Offset.zero,
          width: shape.size,
          height: shape.size,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(shape.size * 0.2)),
          paint,
        );
      } else {
        // Draw Triangle.
        final path = Path();
        final r = shape.size / 2;
        path.moveTo(0, -r);
        path.lineTo(r, r);
        path.lineTo(-r, r);
        path.close();
        canvas.drawPath(path, paint);
      }

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ShapesPainter oldDelegate) => true;
}
