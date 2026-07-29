import 'package:flutter/material.dart';

import '../../models/plan.dart';
import 'progression_help_dialog.dart';

/// Shared, persisted progression projection used by Today and Logger.
///
/// The text is stored on [PlannedExercise], so reopening an existing decision
/// trace cannot silently recalculate a different milestone.
class ProgressionPanel extends StatelessWidget {
  final PlannedExercise exercise;
  final EdgeInsetsGeometry padding;

  const ProgressionPanel({
    super.key,
    required this.exercise,
    this.padding = const EdgeInsets.all(12),
  });

  @override
  Widget build(BuildContext context) {
    final fraction = exercise.progressionFraction;
    final label = exercise.progressionLabel;
    if (fraction == null || label == null) return const SizedBox.shrink();

    final change = exercise.prescriptionChange;
    final progressed = change != null &&
        (change.startsWith('Target increased') ||
            change.startsWith('Load increased') ||
            change.startsWith('New difficulty') ||
            change.startsWith('New technique'));
    final colors = Theme.of(context).colorScheme;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (change != null) ...[
            Row(
              children: [
                Icon(
                  progressed ? Icons.trending_up : Icons.swap_horiz,
                  size: 18,
                  color: colors.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    progressed
                        ? 'Progressed since last time'
                        : 'Prescription changed since last time',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: colors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(change),
            const SizedBox(height: 10),
          ],
          LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 8,
            borderRadius: BorderRadius.circular(99),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: Icon(
                  Icons.info_outline,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
                tooltip: 'Progression rules',
                onPressed: () => showProgressionRulesDialog(context),
              ),
            ],
          ),
          if (exercise.nextProgressionLabel case final next?) ...[
            const SizedBox(height: 2),
            Text(
              next,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}
