import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/analytics_engine.dart';
import '../../engine/schedule_fit_engine.dart';
import '../../models/session_type.dart';
import '../../state/app_controller.dart';

// Okabe-Ito-inspired categorical colors stay fixed across light/dark themes.
// These categories need to remain distinguishable from one another rather
// than inherit several adjacent Material scheme colors.
const timeAllocationWarmupColor = Color(0xFF56B4E9);
const timeAllocationWorkingColor = Color(0xFFE69F00);
const timeAllocationRestColor = Color(0xFF009E73);
const timeAllocationUnaccountedColor = Color(0xFFB8B8B8);

/// Formats a duration for reading, not for precision: minutes above an hour,
/// mm:ss below it, seconds below a minute.
String formatDurationSeconds(num seconds) {
  final total = seconds.round().abs();
  final sign = seconds < 0 ? '-' : '';
  if (total < 60) return '$sign${total}s';
  final minutes = total ~/ 60;
  final rest = total % 60;
  if (minutes < 60) return '$sign$minutes:${rest.toString().padLeft(2, '0')}';
  return '$sign${minutes ~/ 60}h ${(minutes % 60).toString().padLeft(2, '0')}m';
}

/// Signed minutes, for estimate bias where the sign carries the meaning.
String formatSignedMinutes(double seconds) {
  final minutes = seconds / 60;
  final rounded = minutes.abs() < 1
      ? minutes.toStringAsFixed(1)
      : minutes.abs().round().toString();
  return '${seconds >= 0 ? '+' : '−'}$rounded min';
}

String formatMinuteOfDay(double minuteOfDay) {
  final total = minuteOfDay.round().clamp(0, 24 * 60 - 1);
  final hour = total ~/ 60;
  final minute = total % 60;
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

const _weekdayLabels = {
  DateTime.monday: 'Mon',
  DateTime.tuesday: 'Tue',
  DateTime.wednesday: 'Wed',
  DateTime.thursday: 'Thu',
  DateTime.friday: 'Fri',
  DateTime.saturday: 'Sat',
  DateTime.sunday: 'Sun',
};

/// The plain-language takeaway for one session type's estimate bias — the
/// single most actionable output of the whole screen for tuning the planner.
String estimateVerdict(SessionTypeTimeSummary summary) {
  final bias = summary.medianEstimateErrorSeconds;
  if (bias == null) return 'No estimate recorded yet';
  if (summary.sessionCount < 3) {
    return '${formatSignedMinutes(bias)} vs. plan (only ${summary.sessionCount} '
        'session${summary.sessionCount == 1 ? '' : 's'} — not conclusive)';
  }
  if (bias.abs() <= 60) return 'Estimate holds up (${formatSignedMinutes(bias)})';
  return bias > 0
      ? 'Runs ${formatSignedMinutes(bias)} over the estimate'
      : 'Finishes ${formatSignedMinutes(bias)} under the estimate';
}

/// §11.4 companion: everything the app knows about *time* — how long sessions
/// really take, where that time goes, when training happens, and how the
/// optional REHIT actually plays out.
class InsightsScreen extends StatefulWidget {
  /// Test seam, mirroring HistoryScreen's `loadData`.
  final Future<TrainingTimeInsights> Function()? loadData;
  final ScheduleHabits Function()? loadHabits;

  const InsightsScreen({super.key, this.loadData, this.loadHabits});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  late Future<TrainingTimeInsights> _future;
  ScheduleHabits? _habits;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = _load();
  }

  Future<TrainingTimeInsights> _load() {
    final loader = widget.loadData;
    if (loader != null) {
      _habits = widget.loadHabits?.call();
      return loader();
    }
    final controller = context.read<AppController>();
    _habits = controller.scheduleHabitsAt(DateTime.now());
    return controller.loadInsights();
  }

  void _retry() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Training insights')),
      body: SafeArea(
        child: FutureBuilder<TrainingTimeInsights>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _InsightsLoadError(onRetry: _retry);
            }
            final data = snapshot.data;
            if (data == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _WindowHeader(insights: data),
                const SizedBox(height: 12),
                if (data.sessions.isEmpty)
                  const _EmptyState()
                else ...[
                  _EstimateAccuracyCard(summaries: data.bySessionType),
                  const SizedBox(height: 12),
                  _AllocationCard(allocation: data.allocation),
                  const SizedBox(height: 12),
                  _ExerciseCostCard(costs: data.exerciseCosts),
                  const SizedBox(height: 12),
                  _RhythmCard(habits: _habits, latency: data.latency),
                  const SizedBox(height: 12),
                  _RehitFunnelCard(rehit: data.rehit),
                  const SizedBox(height: 12),
                  _ConsistencyCard(consistency: data.consistency),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _InsightsLoadError extends StatelessWidget {
  final VoidCallback onRetry;

  const _InsightsLoadError({required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Could not load training insights.'),
            const SizedBox(height: 8),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Card(
        child: ListTile(
          leading: Icon(Icons.query_stats),
          title: Text('No sessions in this window yet'),
          subtitle: Text(
            'Timing is captured automatically as you log sets — the first few '
            'sessions will fill this in.',
          ),
        ),
      );
}

class _WindowHeader extends StatelessWidget {
  final TrainingTimeInsights insights;

  const _WindowHeader({required this.insights});

  @override
  Widget build(BuildContext context) {
    final timed = insights.sessions
        .where((session) => session.timedSetCount > 0)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Last ${insights.windowDays} days',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Text(
          '${insights.sessions.length} session'
          '${insights.sessions.length == 1 ? '' : 's'} · '
          '$timed with set-by-set timing',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _InsightCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;

  const _InsightCard({
    required this.title,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      );
}

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;
  final String? note;
  final Color? leadingColor;
  final Key? leadingKey;

  const _MetricRow({
    required this.label,
    required this.value,
    this.note,
    this.leadingColor,
    this.leadingKey,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (leadingColor != null) ...[
              Container(
                key: leadingKey,
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(top: 5),
                decoration: BoxDecoration(
                  color: leadingColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  if (note != null)
                    Text(note!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      );
}

class _EstimateAccuracyCard extends StatelessWidget {
  final List<SessionTypeTimeSummary> summaries;

  const _EstimateAccuracyCard({required this.summaries});

  @override
  Widget build(BuildContext context) => _InsightCard(
        title: 'Session length vs. plan',
        subtitle:
            'How long each session type really takes, against what the planner '
            'predicted. A consistent bias is what the duration model needs.',
        children: summaries.isEmpty
            ? [const Text('No completed sessions in this window.')]
            : summaries
                .map(
                  (summary) => _MetricRow(
                    label: sessionTypes[summary.templateId]?.name ??
                        summary.templateId.name,
                    note: '${summary.sessionCount} logged · '
                        '${estimateVerdict(summary)}',
                    value:
                        formatDurationSeconds(summary.medianTotalSeconds),
                  ),
                )
                .toList(),
      );
}

class _AllocationCard extends StatelessWidget {
  final TimeAllocation allocation;

  const _AllocationCard({required this.allocation});

  @override
  Widget build(BuildContext context) {
    if (allocation.sessionCount == 0) {
      return const _InsightCard(
        title: 'Where the time goes',
        children: [
          Text(
            'No set-by-set timing yet. It is recorded automatically from your '
            'next logged session.',
          ),
        ],
      );
    }
    final segments = <({String id, String label, int seconds, Color color})>[
      (
        id: 'warmup',
        label: 'Warm-up',
        seconds: allocation.warmupSeconds,
        color: timeAllocationWarmupColor,
      ),
      (
        id: 'working',
        label: 'Working',
        seconds: allocation.activeSeconds,
        color: timeAllocationWorkingColor,
      ),
      (
        id: 'rest',
        label: 'Rest',
        seconds: allocation.restSeconds,
        color: timeAllocationRestColor,
      ),
      (
        id: 'unaccounted',
        label: 'Unaccounted',
        seconds: allocation.unattributedSeconds,
        color: timeAllocationUnaccountedColor,
      ),
    ];
    return _InsightCard(
      title: 'Where the time goes',
      subtitle:
          'Across ${allocation.sessionCount} timed session'
          '${allocation.sessionCount == 1 ? '' : 's'}. "Working" is everything '
          'beyond the prescribed rest — setup and the set itself. '
          '"Unaccounted" is session time no logged step covers.',
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Row(
            children: [
              for (final segment in segments)
                if (segment.seconds > 0)
                  Expanded(
                    flex: segment.seconds,
                    child: Container(
                      key: ValueKey(
                        'time-allocation-segment-${segment.id}',
                      ),
                      height: 16,
                      color: segment.color,
                    ),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final segment in segments)
          _MetricRow(
            label: segment.label,
            note:
                '${(allocation.fractionOf(segment.seconds) * 100).round()}%',
            value: formatDurationSeconds(segment.seconds),
            leadingColor: segment.color,
            leadingKey: ValueKey('time-allocation-swatch-${segment.id}'),
          ),
      ],
    );
  }
}

class _ExerciseCostCard extends StatelessWidget {
  final List<ExerciseTimeSummary> costs;

  const _ExerciseCostCard({required this.costs});

  @override
  Widget build(BuildContext context) {
    final top = costs.take(8).toList();
    return _InsightCard(
      title: 'Time per exercise',
      subtitle:
          'Median per set, including the rest taken into it — what actually '
          'gets cut when a slot is short.',
      children: top.isEmpty
          ? [const Text('No timed work sets in this window.')]
          : top
              .map(
                (cost) => _MetricRow(
                  label: cost.name,
                  note: '${cost.setCount} sets · '
                      '${formatDurationSeconds(cost.totalSeconds)} total',
                  value:
                      '${formatDurationSeconds(cost.medianSecondsPerSet)}/set',
                ),
              )
              .toList(),
    );
  }
}

class _RhythmCard extends StatelessWidget {
  final ScheduleHabits? habits;
  final LatencyMetrics latency;

  const _RhythmCard({required this.habits, required this.latency});

  @override
  Widget build(BuildContext context) {
    final habits = this.habits;
    final scheme = Theme.of(context).colorScheme;
    return _InsightCard(
      title: 'Your training rhythm',
      subtitle:
          'Observed, not configured — this is also what the rest-day REHIT '
          'reminder aims at.',
      children: [
        if (habits?.medianStartMinuteOfDay != null)
          _MetricRow(
            label: 'Typical start time',
            note: '${habits!.startSampleCount} timed session'
                '${habits.startSampleCount == 1 ? '' : 's'}',
            value: formatMinuteOfDay(habits.medianStartMinuteOfDay!),
          )
        else
          const _MetricRow(
            label: 'Typical start time',
            note: 'Needs a few timed sessions',
            value: '—',
          ),
        if (latency.medianCheckInMinuteOfDay != null)
          _MetricRow(
            label: 'Typical check-in time',
            value: formatMinuteOfDay(latency.medianCheckInMinuteOfDay!),
          ),
        if (latency.medianCheckInToStartSeconds != null)
          _MetricRow(
            label: 'Check-in to starting',
            note: 'How long the plan waits before you train',
            value:
                formatDurationSeconds(latency.medianCheckInToStartSeconds!),
          ),
        if (latency.checkedInWithoutTrainingDays > 0)
          _MetricRow(
            label: 'Checked in but did not train',
            value: '${latency.checkedInWithoutTrainingDays} days',
          ),
        if (habits != null) ...[
          const SizedBox(height: 8),
          for (final weekday in habits.weekdays)
            if (weekday.observedDays > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: Text(_weekdayLabels[weekday.weekday] ?? ''),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: weekday.trainedRatio ?? 0,
                          minHeight: 8,
                          backgroundColor:
                              scheme.primary.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 96,
                      child: Text(
                        '${weekday.trainedDays}/${weekday.observedDays}'
                        '${weekday.medianStartMinuteOfDay == null ? '' : ' · ${formatMinuteOfDay(weekday.medianStartMinuteOfDay!)}'}',
                        textAlign: TextAlign.right,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ],
    );
  }
}

class _RehitFunnelCard extends StatelessWidget {
  final RehitFunnelMetrics rehit;

  const _RehitFunnelCard({required this.rehit});

  @override
  Widget build(BuildContext context) => _InsightCard(
        title: 'REHIT follow-through',
        subtitle:
            'From the app judging a short REHIT worthwhile to the dose actually '
            'being logged.',
        children: [
          _MetricRow(
            label: 'Days it was suggested',
            value: '${rehit.suggestedDays}',
          ),
          _MetricRow(
            label: 'Days a reminder was scheduled',
            value: '${rehit.nudgedDays}',
          ),
          _MetricRow(
            label: 'Days a REHIT was done',
            note: rehit.conversionRate == null
                ? null
                : '${(rehit.conversionRate! * 100).round()}% of suggested days',
            value: '${rehit.completedDays}',
          ),
          if (rehit.medianSuggestionToCompletionSeconds != null)
            _MetricRow(
              label: 'Suggested to done',
              value: formatDurationSeconds(
                rehit.medianSuggestionToCompletionSeconds!,
              ),
            ),
          if (rehit.medianSessionStartToCompletionSeconds != null)
            _MetricRow(
              label: 'Session start to REHIT',
              value: formatDurationSeconds(
                rehit.medianSessionStartToCompletionSeconds!,
              ),
            ),
          if (rehit.medianCompletionMinuteOfDay != null)
            _MetricRow(
              label: 'Typical REHIT time',
              value:
                  formatMinuteOfDay(rehit.medianCompletionMinuteOfDay!),
            ),
        ],
      );
}

class _ConsistencyCard extends StatelessWidget {
  final ConsistencyMetrics consistency;

  const _ConsistencyCard({required this.consistency});

  @override
  Widget build(BuildContext context) {
    final worstWeekday = _mostMissedWeekday(consistency);
    return _InsightCard(
      title: 'Consistency',
      children: [
        _MetricRow(
          label: 'Training days',
          note: consistency.trainedDaysPerWeek == null
              ? null
              : '${consistency.trainedDaysPerWeek!.toStringAsFixed(1)} per week',
          value: '${consistency.trainedDays}/${consistency.windowDays}',
        ),
        _MetricRow(
          label: 'Current streak',
          note: 'Longest in window: ${consistency.longestStreakDays} days',
          value: '${consistency.currentStreakDays} days',
        ),
        if (consistency.daysSinceLastSession != null)
          _MetricRow(
            label: 'Days since last session',
            value: '${consistency.daysSinceLastSession}',
          ),
        if (worstWeekday != null)
          _MetricRow(
            label: 'Most-missed day',
            note: 'Untrained ${consistency.untrainedDaysByWeekday[worstWeekday]} '
                'times in this window',
            value: _weekdayLabels[worstWeekday] ?? '',
          ),
      ],
    );
  }

  int? _mostMissedWeekday(ConsistencyMetrics consistency) {
    int? worst;
    var worstCount = 0;
    for (final entry in consistency.untrainedDaysByWeekday.entries) {
      if (entry.value > worstCount) {
        worst = entry.key;
        worstCount = entry.value;
      }
    }
    return worst;
  }
}
