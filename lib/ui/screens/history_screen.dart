import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/cardio_protocol.dart';
import '../../models/history_data.dart';
import '../../models/movement_pattern.dart';
import '../../models/recovery_snapshot.dart';
import '../../models/session_log.dart';
import '../../models/session_type.dart';
import '../../models/training_status.dart';
import '../../state/app_controller.dart';
import '../view_models/history_feedback_view_model.dart';

/// §11.4 History: personal dose targets, calendar heat, per-pattern
/// progression sparklines, HRV overlay, and session list.
typedef HistoryDataLoader = Future<HistoryData> Function(
  AppController controller,
);

class HistoryScreen extends StatefulWidget {
  final HistoryDataLoader? loadData;

  const HistoryScreen({super.key, this.loadData});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  Future<HistoryData>? _future;
  AppController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<AppController>();
    if (!identical(_controller, controller)) {
      _controller?.removeListener(_handleControllerChanged);
      _controller = controller;
      controller.addListener(_handleControllerChanged);
    }
    _future ??= _load();
  }

  @override
  void didUpdateWidget(covariant HistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loadData != widget.loadData) _future = _load();
  }

  @override
  void dispose() {
    _controller?.removeListener(_handleControllerChanged);
    super.dispose();
  }

  Future<HistoryData> _load() {
    final controller = _controller ?? context.read<AppController>();
    return widget.loadData?.call(controller) ?? controller.loadHistoryData();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(() => _future = _load());
  }

  void _retry() {
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: FutureBuilder<HistoryData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _HistoryLoadError(onRetry: _retry);
          }
          if (!snap.hasData) {
            return _HistoryLoadError(onRetry: _retry);
          }
          final data = snap.data!;
          final logs = data.logs.toList();
          final snaps = data.recoverySnapshots;
          logs.sort((a, b) => a.date.compareTo(b.date));
          final today = DateTime(
            data.asOf.year,
            data.asOf.month,
            data.asOf.day,
          );
          final feedback = HistoryFeedbackViewModel.fromStatus(
            targets: data.targets,
            ledger: data.ledger,
            status: data.trainingStatus,
          );

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TrainingTargetDashboard(viewModel: feedback),
              const SizedBox(height: 12),
              _CalendarHeatCard(logs: logs, today: today),
              const SizedBox(height: 12),
              _ProgressionCard(logs: logs),
              const SizedBox(height: 12),
              _HrvCard(snaps: snaps, today: today),
              const SizedBox(height: 12),
              Text('Sessions', style: Theme.of(context).textTheme.titleMedium),
              if (logs.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Text('No sessions logged yet.')),
              ...logs.reversed.take(30).map((l) => Card(
                    child: ListTile(
                      dense: true,
                      leading: l.travelMode ? const Icon(Icons.luggage_outlined) : null,
                      title: Text('${l.templateId.name.toUpperCase()} - ${l.tier.name}'
                          '${l.travelMode ? ' · travel' : ''}'
                          '${_sessionOriginSuffix(l)}'),
                      subtitle: Text(
                        '${_d(l.date)} - ${historySessionDoseSummary(l)}'
                        '${_sessionCompletionSuffix(l)}',
                      ),
                    ),
                  )),
            ],
          );
        },
      ),
    );
  }
}

class _HistoryLoadError extends StatelessWidget {
  final VoidCallback onRetry;

  const _HistoryLoadError({required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.history_toggle_off_outlined, size: 40),
              const SizedBox(height: 12),
              Text(
                'Could not load history.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}

/// Personal stimulus/target feedback. This is intentionally read-only; the
/// recommendation engine remains the sole owner of workout selection.
class TrainingTargetDashboard extends StatelessWidget {
  final HistoryFeedbackViewModel viewModel;

  const TrainingTargetDashboard({
    super.key,
    required this.viewModel,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          _MuscleTargetsCard(rows: viewModel.muscles),
          const SizedBox(height: 12),
          _CardioTargetsCard(rows: viewModel.cardio),
        ],
      );
}

class _MuscleTargetsCard extends StatelessWidget {
  final List<MuscleTargetRowModel> rows;

  const _MuscleTargetsCard({required this.rows});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Muscle targets',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Targets: 8–12/week (center 10) · 32–48/28d (center 40)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              const _MuscleHeaderRow(),
              const Divider(height: 12),
              for (final row in rows) _MuscleTargetRow(row: row),
            ],
          ),
        ),
      );
}

class _MuscleHeaderRow extends StatelessWidget {
  const _MuscleHeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Row(
      children: [
        Expanded(flex: 3, child: Text('Muscle', style: style)),
        Expanded(
          flex: 2,
          child: Text(
            '7d\n8–12',
            textAlign: TextAlign.end,
            style: style,
          ),
        ),
        Expanded(
          flex: 3,
          child: Text(
            '28d total\n32–48',
            textAlign: TextAlign.end,
            style: style,
          ),
        ),
      ],
    );
  }
}

class _MuscleTargetRow extends StatelessWidget {
  final MuscleTargetRowModel row;

  const _MuscleTargetRow({required this.row});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(flex: 3, child: Text(row.label)),
            Expanded(
              flex: 2,
              child: _TargetDoseCell(
                muscle: row.label,
                horizon: '7 days',
                value: row.effectiveSets7d,
                bandState: row.bandState7d,
              ),
            ),
            Expanded(
              flex: 3,
              child: Tooltip(
                message:
                    '${_sets(row.weeklyEquivalent28d)} sets/week equivalent',
                child: _TargetDoseCell(
                  muscle: row.label,
                  horizon: '28 days',
                  value: row.effectiveSets28d,
                  bandState: row.bandState28d,
                ),
              ),
            ),
          ],
        ),
      );
}

class _TargetDoseCell extends StatelessWidget {
  final String muscle;
  final String horizon;
  final double value;
  final MuscleTargetBandState bandState;

  const _TargetDoseCell({
    required this.muscle,
    required this.horizon,
    required this.value,
    required this.bandState,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color, foreground) = switch (bandState) {
      MuscleTargetBandState.belowMinimum => (
          'Below',
          scheme.errorContainer,
          scheme.onErrorContainer,
        ),
      MuscleTargetBandState.inBand => (
          'In band',
          scheme.primaryContainer,
          scheme.onPrimaryContainer,
        ),
      MuscleTargetBandState.aboveMaximum => (
          'Above',
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer,
        ),
    };
    return Semantics(
      label: '$muscle, $horizon: ${_sets(value)} sets, $label target band',
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(minWidth: 58),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _sets(value),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
              ),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: foreground,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardioTargetsCard extends StatelessWidget {
  final List<CardioTargetRowModel> rows;

  const _CardioTargetsCard({required this.rows});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cardio targets',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Trailing windows · high-intensity days can be Norwegian 4×4 or REHIT',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (final row in rows) _CardioTargetRow(row: row),
            ],
          ),
        ),
      );
}

class _CardioTargetRow extends StatelessWidget {
  final CardioTargetRowModel row;

  const _CardioTargetRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final detail = switch (row.target) {
      AerobicTargetKind.highIntensityDistinctDays =>
        '${row.completedDistinctDays}/${row.targetDistinctDays} DISTINCT DAYS in trailing ${row.rollingWindowDays}d',
      AerobicTargetKind.norwegian4x4Preference =>
        '${row.completedExposures}/${row.targetExposures} in trailing ${row.rollingWindowDays}d',
      AerobicTargetKind.longBaseExposure =>
        '${row.completedExposures}/${row.targetExposures} in trailing ${row.rollingWindowDays}d',
    };
    final note = switch (row.target) {
      AerobicTargetKind.highIntensityDistinctDays => row.met
          ? 'Met — Norwegian 4×4 and REHIT each count once per calendar day'
          : '${row.distinctDayDeficit} distinct high-intensity day${row.distinctDayDeficit == 1 ? '' : 's'} remaining',
      AerobicTargetKind.norwegian4x4Preference => row.met
          ? 'Preference met'
          : row.completedDistinctDays >= 3
              ? 'Replace a REHIT day with 4×4 when a 35/60 min slot is available; do not add a fourth high-intensity day.'
              : 'At least one 4×4 is preferred when a 35/60 min slot is available',
      AerobicTargetKind.longBaseExposure => row.met
          ? 'Exposure met'
          : '${row.exposureDeficit} exposure remaining · secondary to strength deficits',
    };
    final icon = switch (row.state) {
      CardioTargetState.notNeeded => Icons.remove_circle_outline,
      CardioTargetState.met => Icons.check_circle,
      CardioTargetState.deficit => Icons.radio_button_unchecked,
    };
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        icon,
        color: row.state == CardioTargetState.met
            ? Theme.of(context).colorScheme.primary
            : null,
      ),
      title: Text(row.label),
      subtitle: Text('$detail\n$note'),
      isThreeLine: true,
    );
  }
}

String _sets(double value) =>
    (value - value.roundToDouble()).abs() < 0.001
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);

String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _sessionOriginSuffix(SessionLog log) {
  if (log.isUnplanned) return ' · unplanned';
  if (log.isSupplemental) return ' · supplemental';
  return '';
}

String _sessionCompletionSuffix(SessionLog log) {
  if (log.templateId == SessionTypeId.s6 &&
      log.cardioCompletedAsPrescribed == true &&
      !log.cardioDoseQualifies) {
    return ' (completed recovery · no base credit)';
  }
  final supplemental = log.isSupplemental || log.isUnplanned;
  final complete = supplemental
      ? log.countsTowardQueueAndFloor
      : log.completesTodaysPlan;
  return complete ? '' : ' (partial)';
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

// ---------- calendar heat (12 weeks, strength + cardio categories) ----------

/// The heatmap distinguishes training stimulus without converting cardio
/// minutes into strength-set equivalents.
enum HistoryHeatCategory { none, strength, zone2, vo2Rehit }

/// Pure per-day evidence used by the history heatmap. Keeping this outside
/// the widget makes the priority rule and legacy/partial cardio handling
/// independently testable.
class HistoryHeatDay {
  final int strengthSets;
  final List<_CardioHeatDose> _cardio;

  const HistoryHeatDay._({
    required this.strengthSets,
    required List<_CardioHeatDose> cardio,
  }) : _cardio = cardio;

  static const empty = HistoryHeatDay._(
    strengthSets: 0,
    cardio: [],
  );

  bool get hasZone2 =>
      _cardio.any((dose) => dose.category == HistoryHeatCategory.zone2);
  bool get hasVo2Rehit =>
      _cardio.any((dose) => dose.category == HistoryHeatCategory.vo2Rehit);

  /// A single cell has one category even when multiple sessions were logged.
  /// High intensity must not be visually hidden by a same-day base ride.
  HistoryHeatCategory get category => hasVo2Rehit
      ? HistoryHeatCategory.vo2Rehit
      : hasZone2
          ? HistoryHeatCategory.zone2
          : strengthSets > 0
              ? HistoryHeatCategory.strength
              : HistoryHeatCategory.none;

  String tooltip(DateTime date) {
    final parts = <String>[];
    if (strengthSets > 0) parts.add('$strengthSets strength ${strengthSets == 1 ? 'set' : 'sets'}');
    final byCategory = <HistoryHeatCategory, int>{};
    for (final dose in _cardio) {
      byCategory[dose.category] = (byCategory[dose.category] ?? 0) + dose.seconds;
    }
    if (byCategory.containsKey(HistoryHeatCategory.zone2)) {
      parts.add('Zone 2 ${_heatDuration(byCategory[HistoryHeatCategory.zone2]!)}');
    }
    if (byCategory.containsKey(HistoryHeatCategory.vo2Rehit)) {
      parts.add('VO₂/REHIT ${_heatDuration(byCategory[HistoryHeatCategory.vo2Rehit]!)}');
    }
    return '${_d(date)}: ${parts.isEmpty ? 'No logged training' : parts.join(' · ')}';
  }

  static Map<String, HistoryHeatDay> project(List<SessionLog> logs) {
    final strength = <String, int>{};
    final cardio = <String, List<_CardioHeatDose>>{};
    for (final log in logs) {
      final key = '${log.date.year}-${log.date.month}-${log.date.day}';
      if (log.completedWorkSets > 0) {
        strength[key] = (strength[key] ?? 0) + log.completedWorkSets;
      }
      final dose = _cardioDoseFor(log);
      if (dose != null) cardio.putIfAbsent(key, () => []).add(dose);
    }
    final keys = {...strength.keys, ...cardio.keys};
    return {
      for (final key in keys)
        key: HistoryHeatDay._(
          strengthSets: strength[key] ?? 0,
          cardio: List.unmodifiable(cardio[key] ?? const <_CardioHeatDose>[]),
        ),
    };
  }

  static _CardioHeatDose? _cardioDoseFor(SessionLog log) {
    final protocol = log.cardioCompletion?.protocol.type;
    final isHighIntensity = log.rehitFinisherCompleted ||
        log.templateId == SessionTypeId.s3 ||
        log.templateId == SessionTypeId.s7 ||
        protocol == CardioProtocolType.norwegian4x4 ||
        protocol == CardioProtocolType.rehit;
    final category = isHighIntensity
        ? HistoryHeatCategory.vo2Rehit
        : (log.templateId == SessionTypeId.s6 ||
                protocol == CardioProtocolType.zone2Base)
            ? HistoryHeatCategory.zone2
            : null;
    if (category == null) return null;
    // A structured partial is still a genuine logged attempt. Legacy cardio
    // rows have no seconds detail, so their logged duration remains honest.
    final seconds = log.cardioCompletion?.completedDurationSeconds ??
        log.durationMinutes * 60;
    return _CardioHeatDose(category, seconds);
  }
}

class _CardioHeatDose {
  final HistoryHeatCategory category;
  final int seconds;
  const _CardioHeatDose(this.category, this.seconds);
}

String _heatDuration(int seconds) {
  if (seconds <= 0) return 'logged';
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return remainder == 0
      ? '${minutes}m'
      : '$minutes:${remainder.toString().padLeft(2, '0')}';
}

class _CalendarHeatCard extends StatelessWidget {
  final List<SessionLog> logs;
  final DateTime today;

  const _CalendarHeatCard({required this.logs, required this.today});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // grid ends on today's week (Mon-first), 12 columns of weeks
    final weekday = today.weekday; // 1 = Mon
    final gridEnd = today.add(Duration(days: 7 - weekday));
    final days = HistoryHeatDay.project(logs);
    final maxSets = days.values
        .map((day) => day.strengthSets)
        .fold(1, (a, b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Last 12 weeks', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(12, (w) {
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: Column(
                      children: List.generate(7, (d) {
                        final day = gridEnd.subtract(Duration(days: (11 - w) * 7 + (6 - d)));
                        final future = day.isAfter(today);
                        final evidence = days['${day.year}-${day.month}-${day.day}'] ??
                            HistoryHeatDay.empty;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1.5),
                          child: Tooltip(
                            message: evidence.tooltip(day),
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(3),
                                  color: future
                                      ? Colors.transparent
                                      : _heatColor(evidence, scheme, maxSets),
                                  border: _sameDay(day, today)
                                      ? Border.all(color: scheme.onSurface, width: 1)
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                _HeatLegend(
                  key: const ValueKey('history-heat-legend-strength'),
                  label: 'Strength',
                  color: scheme.error,
                ),
                _HeatLegend(
                  key: const ValueKey('history-heat-legend-zone2'),
                  label: 'Zone 2',
                  color: scheme.secondary,
                ),
                _HeatLegend(
                  key: const ValueKey('history-heat-legend-vo2-rehit'),
                  label: 'VO₂/REHIT',
                  color: scheme.tertiary,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Strength shade = completed sets · cardio color = session type; tooltip shows logged dose',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Color _heatColor(
    HistoryHeatDay day,
    ColorScheme scheme,
    int maxSets,
  ) => switch (day.category) {
        HistoryHeatCategory.none => scheme.surfaceContainerHighest,
        HistoryHeatCategory.strength => scheme.error.withValues(
            alpha: 0.35 + 0.65 * (day.strengthSets / maxSets),
          ),
        HistoryHeatCategory.zone2 => scheme.secondary.withValues(alpha: 0.78),
        HistoryHeatCategory.vo2Rehit => scheme.tertiary.withValues(alpha: 0.86),
      };
}

class _HeatLegend extends StatelessWidget {
  final String label;
  final Color color;

  const _HeatLegend({
    super.key,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

// ---------- per-pattern progression sparklines ----------

class _ProgressionCard extends StatelessWidget {
  final List<SessionLog> logs;

  const _ProgressionCard({required this.logs});

  static const _patterns = [
    MovementPattern.squat,
    MovementPattern.hinge,
    MovementPattern.pushHorizontal,
    MovementPattern.pushVertical,
    MovementPattern.pullVertical,
    MovementPattern.pullHorizontal,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (final p in _patterns) {
      // top completed work-set weight per session, oldest -> newest
      final points = <double>[];
      for (final l in logs) {
        double top = 0;
        for (final s in l.setLogs) {
          if (s.isWarmup || s.pattern != p || s.trackKey != p.name) continue;
          if (s.weight > top) top = s.weight;
        }
        if (top > 0) points.add(top);
      }
      if (points.isEmpty) continue;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(width: 110, child: Text(p.displayName, style: Theme.of(context).textTheme.bodySmall)),
            Expanded(
              child: SizedBox(
                height: 28,
                child: CustomPaint(painter: _SparklinePainter(points, scheme.primary)),
              ),
            ),
            const SizedBox(width: 8),
            Text('${points.last.toStringAsFixed(0)} lb', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ));
    }
    if (rows.isEmpty) {
      rows.add(Text('Log a few sessions and the progression lines appear here.',
          style: Theme.of(context).textTheme.bodySmall));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Progression (top set, 12 weeks)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...rows,
          ],
        ),
      ),
    );
  }
}

// ---------- HRV overlay ----------

class _HrvCard extends StatelessWidget {
  final List<RecoverySnapshot> snaps;
  final DateTime today;

  const _HrvCard({required this.snaps, required this.today});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final values = (snaps.toList()..sort((a, b) => a.date.compareTo(b.date)))
        .map((s) => s.hrvRmssd)
        .whereType<double>()
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('HRV, last 28 days', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (values.length < 2)
              Text('Not enough HRV data yet — connect Oura or enter it at check-in.',
                  style: Theme.of(context).textTheme.bodySmall)
            else
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 40,
                      child: CustomPaint(painter: _SparklinePainter(values, scheme.tertiary)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${values.last.toStringAsFixed(0)} ms', style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> points;
  final Color color;

  _SparklinePainter(this.points, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final min = points.reduce((a, b) => a < b ? a : b);
    final max = points.reduce((a, b) => a > b ? a : b);
    final range = (max - min) == 0 ? 1.0 : (max - min);
    final dx = size.width / (points.length - 1);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = i * dx;
      final y = size.height - ((points[i] - min) / range) * (size.height - 4) - 2;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    // end-point marker
    final lastY = size.height - ((points.last - min) / range) * (size.height - 4) - 2;
    canvas.drawCircle(Offset(size.width, lastY), 3, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) => old.points != points || old.color != color;
}
