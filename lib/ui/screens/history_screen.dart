import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/stimulus_ledger_engine.dart';
import '../../models/bouldering_log.dart';
import '../../models/cardio_protocol.dart';
import '../../models/exercise_metric.dart';
import '../../models/history_data.dart';
import '../../models/movement_pattern.dart';
import '../../models/plan.dart';
import '../../models/recovery_snapshot.dart';
import '../../models/session_log.dart';
import '../../models/session_type.dart';
import '../../models/set_log.dart';
import '../../models/stimulus_ledger.dart';
import '../../models/training_status.dart';
import '../../models/training_targets.dart';
import '../../state/app_controller.dart';
import '../view_models/history_feedback_view_model.dart';
import '../widgets/anatomical_muscle_map.dart';

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
    setState(() {
      _future = _load();
    });
  }

  void _retry() {
    setState(() {
      _future = _load();
    });
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
          final boulderingLogs = data.boulderingLogs.toList()
            ..sort((a, b) => a.date.compareTo(b.date));
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
          final controller = context.read<AppController>();
          final trace = controller.todayTrace;
          final todayPlan = trace != null && _sameDay(trace.date, today)
              ? trace.plan
              : null;
          final progressionSince = today.subtract(const Duration(days: 84));

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TrainingTargetDashboard(viewModel: feedback),
              const SizedBox(height: 12),
              MuscleMapCard(
                ledger: data.ledger,
                status: data.trainingStatus,
                todayExercises: todayPlan?.exercises ?? const [],
              ),
              const SizedBox(height: 12),
              if (controller.settings.classicHeatmap)
                _ClassicCalendarHeatCard(logs: logs, today: today)
              else
                _YearActivityHeatCard(
                  logs: logs,
                  boulderingLogs: boulderingLogs,
                  today: today,
                ),
              const SizedBox(height: 12),
              _ProgressionCard(
                logs: logs
                    .where((log) => !log.date.isBefore(progressionSince))
                    .toList(),
              ),
              const SizedBox(height: 12),
              _HrvCard(snaps: snaps, today: today),
              const SizedBox(height: 12),
              Text(
                'Activity log',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (logs.isEmpty && boulderingLogs.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No activity logged yet.'),
                ),
              ...boulderingLogs.reversed.take(30).map(
                    (log) => Card(
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.terrain),
                        title: Text(
                          'Bouldering · ${_boulderingEffortLabel(log.effort)}',
                        ),
                        subtitle: Text(
                          '${_d(log.date)} · ${log.durationMinutes} min · '
                          'estimated pull/grip stimulus',
                        ),
                      ),
                    ),
                  ),
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

// ---------- annual activity heat (53 weeks, stable time scale) ----------

/// A day in the default activity heatmap. Levels are fixed rather than
/// recalculated from the user's own quartiles, so a 20-minute workout keeps
/// the same meaning as more history is added.
class HistoryActivityDay {
  final int elapsedSeconds;
  final List<SessionLog> logs;
  final List<BoulderingLog> boulderingLogs;

  HistoryActivityDay({
    required this.elapsedSeconds,
    required List<SessionLog> logs,
    required List<BoulderingLog> boulderingLogs,
  })  : logs = List<SessionLog>.unmodifiable(logs),
        boulderingLogs = List<BoulderingLog>.unmodifiable(boulderingLogs);

  static final empty = HistoryActivityDay(
    elapsedSeconds: 0,
    logs: const [],
    boulderingLogs: const [],
  );

  int get level {
    if (elapsedSeconds <= 0) return 0;
    if (elapsedSeconds < 10 * 60) return 1;
    if (elapsedSeconds < 20 * 60) return 2;
    if (elapsedSeconds < 35 * 60) return 3;
    return 4;
  }

  String tooltip(DateTime date) =>
      '${_d(date)}: ${logs.isEmpty && boulderingLogs.isEmpty ? 'No logged training' : '${_heatDuration(elapsedSeconds)} trained · ${logs.length + boulderingLogs.length} ${(logs.length + boulderingLogs.length) == 1 ? 'activity' : 'activities'}'}';

  static Map<String, HistoryActivityDay> project(
    List<SessionLog> logs, {
    List<BoulderingLog> boulderingLogs = const [],
  }) {
    final grouped = <String, List<SessionLog>>{};
    final groupedBouldering = <String, List<BoulderingLog>>{};
    for (final log in logs) {
      final key = '${log.date.year}-${log.date.month}-${log.date.day}';
      grouped.putIfAbsent(key, () => []).add(log);
    }
    for (final log in boulderingLogs) {
      final key = '${log.date.year}-${log.date.month}-${log.date.day}';
      groupedBouldering.putIfAbsent(key, () => []).add(log);
    }
    final keys = {...grouped.keys, ...groupedBouldering.keys};
    return {
      for (final key in keys)
        key: HistoryActivityDay(
          elapsedSeconds: (grouped[key] ?? const []).fold<int>(
            0,
            (sum, log) => sum + log.elapsedSecondsOrEstimate,
          ) +
              (groupedBouldering[key] ?? const []).fold<int>(
                0,
                (sum, log) => sum + log.durationMinutes * 60,
              ),
          logs: grouped[key] ?? const [],
          boulderingLogs: groupedBouldering[key] ?? const [],
        ),
    };
  }
}

class _YearActivityHeatCard extends StatefulWidget {
  final List<SessionLog> logs;
  final List<BoulderingLog> boulderingLogs;
  final DateTime today;

  const _YearActivityHeatCard({
    required this.logs,
    required this.boulderingLogs,
    required this.today,
  });

  @override
  State<_YearActivityHeatCard> createState() => _YearActivityHeatCardState();
}

class _YearActivityHeatCardState extends State<_YearActivityHeatCard> {
  static const _cell = 12.0;
  static const _gap = 3.0;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
  }

  @override
  void didUpdateWidget(covariant _YearActivityHeatCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.today != widget.today) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
    }
  }

  void _scrollToLatest() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime(widget.today.year, widget.today.month, widget.today.day);
    final gridEnd = today.add(Duration(days: 7 - today.weekday));
    final gridStart = gridEnd.subtract(const Duration(days: 370));
    final days = HistoryActivityDay.project(
      widget.logs,
      boulderingLogs: widget.boulderingLogs,
    );
    final trainedDays = days.values.where((day) => day.elapsedSeconds > 0).length;
    final activeWeeks = <String>{
      for (final log in widget.logs)
        '${log.date.subtract(Duration(days: log.date.weekday - 1)).year}-${log.date.subtract(Duration(days: log.date.weekday - 1)).month}-${log.date.subtract(Duration(days: log.date.weekday - 1)).day}',
      for (final log in widget.boulderingLogs)
        '${log.date.subtract(Duration(days: log.date.weekday - 1)).year}-${log.date.subtract(Duration(days: log.date.weekday - 1)).month}-${log.date.subtract(Duration(days: log.date.weekday - 1)).day}',
    }.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Activity · last 12 months',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            Text(
              '$trainedDays training days · $activeWeeks active weeks · by time trained',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Column(
                    children: const [
                      SizedBox(height: _cell, child: Text('M')),
                      SizedBox(height: _gap + _cell),
                      SizedBox(height: _cell, child: Text('W')),
                      SizedBox(height: _gap + _cell),
                      SizedBox(height: _cell, child: Text('F')),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    key: const Key('year-activity-heat-scroll'),
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 18,
                          width: 53 * (_cell + _gap),
                          child: Stack(
                            children: _monthLabels(gridStart),
                          ),
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: List.generate(53, (week) {
                            return Padding(
                              padding: const EdgeInsets.only(right: _gap),
                              child: Column(
                                children: List.generate(7, (weekday) {
                                  final date = gridStart.add(
                                    Duration(days: week * 7 + weekday),
                                  );
                                  final future = date.isAfter(today);
                                  final evidence = days[
                                        '${date.year}-${date.month}-${date.day}'
                                      ] ??
                                      HistoryActivityDay.empty;
                                  final cell = Container(
                                    key: ValueKey('activity-day-${_d(date)}'),
                                    width: _cell,
                                    height: _cell,
                                    decoration: BoxDecoration(
                                      color: future
                                          ? Colors.transparent
                                          : _activityColor(
                                              evidence.level,
                                              scheme,
                                            ),
                                      borderRadius: BorderRadius.circular(3),
                                      border: _sameDay(date, today)
                                          ? Border.all(
                                              color: scheme.onSurface,
                                              width: 1,
                                            )
                                          : null,
                                    ),
                                  );
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: _gap),
                                    child: Semantics(
                                      label: evidence.tooltip(date),
                                      button: evidence.logs.isNotEmpty ||
                                          evidence.boulderingLogs.isNotEmpty,
                                      child: Tooltip(
                                        message: evidence.tooltip(date),
                                        child: GestureDetector(
                                          onTap: evidence.logs.isEmpty &&
                                                  evidence.boulderingLogs.isEmpty
                                              ? null
                                              : () => _showDay(
                                                    context,
                                                    date,
                                                    evidence,
                                                  ),
                                          child: cell,
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            );
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('Less time', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 6),
                for (var level = 0; level <= 4; level++) ...[
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _activityColor(level, scheme),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 3),
                ],
                Text('More time', style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Fixed scale: <10 · 10–19 · 20–34 · 35+ minutes. Tap a trained day for details.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _monthLabels(DateTime gridStart) {
    final labels = <Widget>[];
    var previousMonth = 0;
    for (var week = 0; week < 53; week++) {
      final date = gridStart.add(Duration(days: week * 7));
      if (date.month == previousMonth) continue;
      previousMonth = date.month;
      labels.add(Positioned(
        left: week * (_cell + _gap),
        child: Text(
          const [
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
          ][date.month - 1],
          style: const TextStyle(fontSize: 10),
        ),
      ));
    }
    return labels;
  }

  Color _activityColor(int level, ColorScheme scheme) {
    if (level == 0) return scheme.surfaceContainerHighest;
    return Color.lerp(
      scheme.primaryContainer,
      scheme.primary,
      const [0.0, 0.12, 0.4, 0.7, 1.0][level],
    )!;
  }

  void _showDay(
    BuildContext context,
    DateTime date,
    HistoryActivityDay day,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_d(date), style: Theme.of(context).textTheme.titleLarge),
              Text('${_heatDuration(day.elapsedSeconds)} total training'),
              const SizedBox(height: 8),
              for (final log in day.logs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.check_circle_outline),
                  title: Text(log.templateId.name.toUpperCase()),
                  subtitle: Text(historySessionDoseSummary(log)),
                ),
              for (final log in day.boulderingLogs)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.terrain),
                  title: const Text('Bouldering'),
                  subtitle: Text(
                    '${log.durationMinutes} min · '
                    '${_boulderingEffortLabel(log.effort)} effort',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _boulderingEffortLabel(BoulderingEffort effort) => switch (effort) {
      BoulderingEffort.easy => 'Easy',
      BoulderingEffort.moderate => 'Moderate',
      BoulderingEffort.hard => 'Hard',
    };

// ---------- muscle map (rendering of existing ledger only) ----------

enum _MuscleMapMode { dose, recency, today }

class MuscleMapCard extends StatefulWidget {
  final StimulusLedgerSnapshot ledger;
  final TrainingStatus status;
  final List<PlannedExercise> todayExercises;

  const MuscleMapCard({
    super.key,
    required this.ledger,
    required this.status,
    this.todayExercises = const [],
  });

  @override
  State<MuscleMapCard> createState() => _MuscleMapCardState();
}

class _MuscleMapCardState extends State<MuscleMapCard> {
  _MuscleMapMode _mode = _MuscleMapMode.dose;

  @override
  Widget build(BuildContext context) {
    final values = _values();
    final title = switch (_mode) {
      _MuscleMapMode.dose => 'Completed effective sets in the trailing 28 days',
      _MuscleMapMode.recency => 'Days since last qualifying stimulus — not a fatigue score',
      _MuscleMapMode.today => 'Expected qualifying set contribution in today’s plan',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Muscle map', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<_MuscleMapMode>(
                segments: const [
                  ButtonSegment(
                    value: _MuscleMapMode.dose,
                    label: Text('28-day dose'),
                  ),
                  ButtonSegment(
                    value: _MuscleMapMode.recency,
                    label: Text('Recency'),
                  ),
                  ButtonSegment(
                    value: _MuscleMapMode.today,
                    label: Text('Today'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (value) => setState(() {
                  _mode = value.single;
                }),
              ),
            ),
            const SizedBox(height: 8),
            Text(title, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Semantics(
              label: 'Front and back muscle map',
              child: SizedBox(
                height: 230,
                width: double.infinity,
                child: AnatomicalMuscleMap(values: values),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: MajorMuscleGroup.values.map((muscle) {
                final value = values[muscle] ?? 0;
                return Text(
                  '${_muscleLabel(muscle)} ${_muscleValue(muscle, value)}',
                  style: Theme.of(context).textTheme.labelSmall,
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Map<MajorMuscleGroup, double> _values() {
    if (_mode == _MuscleMapMode.dose) {
      return {
        for (final row in widget.status.muscle)
          row.muscleGroup: row.maximumTargetEffectiveSets <= 0
              ? 0
              : (row.completedEffectiveSets /
                      row.maximumTargetEffectiveSets)
                  .clamp(0.0, 1.0),
      };
    }
    if (_mode == _MuscleMapMode.recency) {
      return {
        for (final muscle in MajorMuscleGroup.values)
          muscle: _recencyLevel(
            widget.ledger.muscle(muscle).daysSinceLastStimulus,
          ),
      };
    }
    final totals = {for (final muscle in MajorMuscleGroup.values) muscle: 0.0};
    const map = ExerciseMuscleMap();
    for (final exercise in widget.todayExercises) {
      if (exercise.isWarmup || exercise.rirTarget == Rir.rir4plus) continue;
      final contribution = map.contributionForExercise(
        trackKey: exercise.trackKey,
        pattern: exercise.pattern,
        exerciseName: exercise.name,
      );
      for (final entry in contribution.entries) {
        totals[entry.key] = totals[entry.key]! + entry.value * exercise.sets;
      }
    }
    final max = totals.values.fold<double>(0, (a, b) => a > b ? a : b);
    if (max == 0) return totals;
    return totals.map((key, value) => MapEntry(key, value / max));
  }

  double _recencyLevel(int? days) {
    if (days == null) return 0;
    if (days <= 1) return 1;
    if (days == 2) return 0.75;
    if (days <= 4) return 0.45;
    return 0.18;
  }

  String _muscleValue(MajorMuscleGroup muscle, double normalized) {
    if (_mode == _MuscleMapMode.dose) {
      return _sets(widget.ledger.muscle(muscle).effectiveSets28d);
    }
    if (_mode == _MuscleMapMode.recency) {
      final days = widget.ledger.muscle(muscle).daysSinceLastStimulus;
      return days == null ? 'never' : '${days}d';
    }
    return normalized <= 0 ? '—' : 'planned';
  }
}

String _muscleLabel(MajorMuscleGroup muscle) => switch (muscle) {
      MajorMuscleGroup.quads => 'Quads',
      MajorMuscleGroup.glutes => 'Glutes',
      MajorMuscleGroup.hamstrings => 'Hamstrings',
      MajorMuscleGroup.chest => 'Chest',
      MajorMuscleGroup.back => 'Back',
      MajorMuscleGroup.delts => 'Delts',
      MajorMuscleGroup.biceps => 'Biceps',
      MajorMuscleGroup.triceps => 'Triceps',
      MajorMuscleGroup.coreGrip => 'Core/grip',
    };

class _ClassicCalendarHeatCard extends StatelessWidget {
  final List<SessionLog> logs;
  final DateTime today;

  const _ClassicCalendarHeatCard({required this.logs, required this.today});

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
    MovementPattern.coreGrip,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (final p in _patterns) {
      if (p == MovementPattern.coreGrip) {
        final timedEntries = <({String name, int seconds})>[];
        for (final log in logs) {
          final sets = log.setLogs
              .where((setLog) =>
                  !setLog.isWarmup &&
                  setLog.pattern == p &&
                  setLog.trackKey == p.name &&
                  setLog.metric == ExerciseMetric.seconds &&
                  setLog.value > 0)
              .toList();
          if (sets.isEmpty) continue;
          final name = sets.last.exerciseName;
          final top = sets
              .where((setLog) => setLog.exerciseName == name)
              .map((setLog) => setLog.value)
              .reduce((a, b) => a > b ? a : b);
          timedEntries.add((name: name, seconds: top));
        }
        if (timedEntries.isEmpty) continue;

        final latestName = timedEntries.last.name;
        final points = timedEntries
            .where((entry) => entry.name == latestName)
            .map((entry) => entry.seconds.toDouble())
            .toList();
        final difficulties = <String>[];
        for (final entry in timedEntries) {
          if (difficulties.isEmpty || difficulties.last != entry.name) {
            difficulties.add(entry.name);
          }
        }
        rows.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 110,
                child: Text(
                  p.displayName,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: SizedBox(
                  key: ValueKey(
                    'progression-sparkline-${p.name}',
                  ),
                  height: 28,
                  child: CustomPaint(
                    painter: _SparklinePainter(points, scheme.primary),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${timedEntries.last.seconds} s',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ));
        if (latestName != p.displayName) {
          rows.add(Padding(
            padding: const EdgeInsets.only(left: 110, top: 2, bottom: 2),
            child: Text(
              'Latest: $latestName',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ));
        }
        if (difficulties.length > 1) {
          rows.add(Padding(
            padding: const EdgeInsets.only(left: 110, top: 2),
            child: Text(
              'Difficulty history: ${difficulties.join(' → ')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ));
        }
        continue;
      }
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
