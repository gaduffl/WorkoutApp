import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/training_targets.dart';
import 'muscle_map_paths.dart';
import 'svg_path_parser.dart';

/// Anatomical front/back projection of MorningCoach's existing muscle ledger.
class AnatomicalMuscleMap extends StatelessWidget {
  final Map<MajorMuscleGroup, double> values;

  const AnatomicalMuscleMap({super.key, required this.values});

  @override
  Widget build(BuildContext context) => Column(
        children: [
          const Row(
            children: [
              Expanded(child: Center(child: Text('Front'))),
              Expanded(child: Center(child: Text('Back'))),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: CustomPaint(
              key: const Key('anatomical-muscle-map-paint'),
              painter: AnatomicalMuscleMapPainter(
                values: values,
                colorScheme: Theme.of(context).colorScheme,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      );
}

@visibleForTesting
MajorMuscleGroup? majorMuscleGroupForAnatomicalSlug(String slug) =>
    switch (slug) {
      'quadriceps' => MajorMuscleGroup.quads,
      'gluteal' => MajorMuscleGroup.glutes,
      'hamstring' => MajorMuscleGroup.hamstrings,
      'chest' => MajorMuscleGroup.chest,
      'upper-back' || 'trapezius' => MajorMuscleGroup.back,
      'deltoids' => MajorMuscleGroup.delts,
      'biceps' => MajorMuscleGroup.biceps,
      'triceps' => MajorMuscleGroup.triceps,
      'abs' || 'obliques' || 'serratus' || 'forearm' =>
        MajorMuscleGroup.coreGrip,
      _ => null,
    };

class AnatomicalMuscleMapPainter extends CustomPainter {
  final Map<MajorMuscleGroup, double> values;
  final ColorScheme colorScheme;

  const AnatomicalMuscleMapPainter({
    required this.values,
    required this.colorScheme,
  });

  static final Map<String, ui.Path> _pathCache = {};

  @override
  void paint(Canvas canvas, Size size) {
    final gap = size.width * 0.04;
    final availableWidth = size.width - gap;
    final bodyWidth = availableWidth / 2;
    final bodyHeight = bodyWidth / (727 / 1280);
    final drawHeight = bodyHeight.clamp(0.0, size.height);
    final drawWidth = drawHeight * 727 / 1280;
    final left = (size.width - drawWidth * 2 - gap) / 2;
    final top = (size.height - drawHeight) / 2;
    _drawBody(canvas, maleFrontMuscleMap, Offset(left, top), drawWidth, drawHeight);
    _drawBody(
      canvas,
      maleBackMuscleMap,
      Offset(left + drawWidth + gap, top),
      drawWidth,
      drawHeight,
    );
  }

  void _drawBody(
    Canvas canvas,
    MuscleMapBody body,
    Offset offset,
    double width,
    double height,
  ) {
    final scale = width / body.width;
    final base = colorScheme.surfaceContainerHighest;
    final outline = Paint()
      ..color = colorScheme.outlineVariant.withValues(alpha: 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8 / scale;
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale, height / body.height);
    canvas.translate(-body.left, -body.top);
    for (final group in body.groups) {
      final muscle = majorMuscleGroupForAnatomicalSlug(group.slug);
      final strength = muscle == null
          ? 0.0
          : (values[muscle] ?? 0).clamp(0.0, 1.0);
      final fill = Paint()
        ..color = muscle == null
            ? base
            : Color.lerp(
                colorScheme.primaryContainer.withValues(alpha: 0.42),
                colorScheme.primary,
                strength,
              )!;
      for (final data in group.paths) {
        final path = _pathCache.putIfAbsent(data, () => parseSvgPathData(data));
        canvas.drawPath(path, fill);
        canvas.drawPath(path, outline);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AnatomicalMuscleMapPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.colorScheme != colorScheme;
}
