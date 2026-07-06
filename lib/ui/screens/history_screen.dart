import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/repository.dart';
import '../../models/floor_category.dart';
import '../../models/movement_pattern.dart';
import '../../models/recovery_snapshot.dart';
import '../../models/session_log.dart';
import '../../state/app_controller.dart';

/// §11.4 History: calendar heat, floor-compliance ring (rolling 7 days),
/// per-pattern progression sparklines, HRV overlay, session list.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<Repository>();
    final controller = context.read<AppController>();
    final today = controller.today();

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: FutureBuilder<(List<SessionLog>, List<RecoverySnapshot>)>(
        future: () async {
          final logs = await repo.loadSessionLogsSince(today.subtract(const Duration(days: 84)));
          final snaps = await repo.loadRecoverySnapshotsSince(today.subtract(const Duration(days: 28)));
          return (logs, snaps);
        }(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final (logs, snaps) = snap.data!;
          logs.sort((a, b) => a.date.compareTo(b.date));

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _FloorRingCard(logs: logs, today: today),
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
                      title: Text('${l.templateId.name.toUpperCase()} - ${l.tier.name}'),
                      subtitle: Text(
                        '${_d(l.date)} - ${l.completedWorkSets}/${l.plannedWorkSets} sets - ${l.durationMinutes} min'
                        '${l.countsTowardQueueAndFloor ? '' : ' (partial)'}',
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

String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

// ---------- rolling 7-day floor ring ----------

class _FloorRingCard extends StatelessWidget {
  final List<SessionLog> logs;
  final DateTime today;

  const _FloorRingCard({required this.logs, required this.today});

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    final last7 = today.subtract(const Duration(days: 7));
    int count(FloorCategory c) => logs
        .where((l) => l.countsAs.contains(c) && l.countsTowardQueueAndFloor && !l.date.isBefore(last7))
        .length;
    final strength = count(FloorCategory.strength);
    final intensity = count(FloorCategory.intensity);
    final strengthReq = controller.settings.weeklyFloor[FloorCategory.strength] ?? 2;
    final intensityReq = controller.settings.weeklyFloor[FloorCategory.intensity] ?? 1;
    final scheme = Theme.of(context).colorScheme;

    Widget ring(String label, int done, int req, Color color) {
      final ok = done >= req;
      return Expanded(
        child: Column(
          children: [
            SizedBox(
              width: 76,
              height: 76,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 76,
                    height: 76,
                    child: CircularProgressIndicator(
                      value: req == 0 ? 1 : (done / req).clamp(0.0, 1.0),
                      strokeWidth: 7,
                      backgroundColor: scheme.surfaceContainerHighest,
                      color: color,
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                  Text('$done/$req', style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text('$label ${ok ? '✓' : ''}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rolling 7-day floor', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(children: [
              ring('Strength', strength, strengthReq, scheme.primary),
              ring('Intensity', intensity, intensityReq, scheme.tertiary),
            ]),
          ],
        ),
      ),
    );
  }
}

// ---------- calendar heat (12 weeks, sequential single hue) ----------

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
    final setsByDay = <String, int>{};
    for (final l in logs) {
      setsByDay['${l.date.year}-${l.date.month}-${l.date.day}'] =
          (setsByDay['${l.date.year}-${l.date.month}-${l.date.day}'] ?? 0) + l.completedWorkSets;
    }
    final maxSets = setsByDay.values.fold(1, (a, b) => a > b ? a : b);

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
                        final sets = setsByDay['${day.year}-${day.month}-${day.day}'] ?? 0;
                        final t = sets == 0 ? 0.0 : 0.35 + 0.65 * (sets / maxSets);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1.5),
                          child: Tooltip(
                            message: '${_d(day)}: $sets sets',
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(3),
                                  color: future
                                      ? Colors.transparent
                                      : sets == 0
                                          ? scheme.surfaceContainerHighest
                                          : scheme.primary.withValues(alpha: t),
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
            Text('Cell shade = completed work sets that day', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
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
