import 'package:flutter/material.dart';

/// Displays the Progression Rules summary matrix explaining how Reps/Seconds
/// and RIR (Reps in Reserve) drive advancement, maintenance, and regression.
Future<void> showProgressionRulesDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      final textTheme = Theme.of(context).textTheme;

      Widget ruleRow({
        required String performance,
        required String rir,
        required String result,
        required Color badgeColor,
        required Color badgeTextColor,
      }) {
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '$performance · $rir',
                      style: textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: badgeColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      result,
                      style: textTheme.labelSmall?.copyWith(
                        color: badgeTextColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      }

      return AlertDialog(
        title: const Text('Progression Rules'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Both Reps/Seconds and RIR (Reps in Reserve) influence your progression.',
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Summary Matrix',
                style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ruleRow(
                performance: 'At/above top target',
                rir: 'RIR 2+',
                result: 'Progression earned',
                badgeColor: scheme.primaryContainer,
                badgeTextColor: scheme.onPrimaryContainer,
              ),
              ruleRow(
                performance: 'At/above top target',
                rir: 'RIR 1',
                result: 'Maintain / Repeat',
                badgeColor: scheme.secondaryContainer,
                badgeTextColor: scheme.onSecondaryContainer,
              ),
              ruleRow(
                performance: 'Inside target range',
                rir: 'RIR 1–2+',
                result: 'Maintain / Repeat',
                badgeColor: scheme.secondaryContainer,
                badgeTextColor: scheme.onSecondaryContainer,
              ),
              ruleRow(
                performance: 'Below lower limit',
                rir: 'Any RIR',
                result: 'Hold / Regression',
                badgeColor: scheme.errorContainer,
                badgeTextColor: scheme.onErrorContainer,
              ),
              ruleRow(
                performance: 'Any rep count',
                rir: 'RIR 0 (Failure)',
                result: 'Hold / Regression',
                badgeColor: scheme.errorContainer,
                badgeTextColor: scheme.onErrorContainer,
              ),
              const SizedBox(height: 12),
              Text(
                'Key Guidelines:',
                style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                '• Hit top target with RIR 2+ on ALL sets to earn higher load, longer hold, or next difficulty stage.\n'
                '• RIR 1 or staying inside target range keeps weight stable for the next session.\n'
                '• RIR 0 (failure) or dropping below minimum reps signals an overreach and triggers a hold warning.\n'
                '• Unperformed sets or skipped exercises do not advance progression.',
                style: textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
