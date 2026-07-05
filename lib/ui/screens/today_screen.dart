import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/ai_explainer.dart';
import '../../models/decision_trace.dart';
import '../../state/app_controller.dart';
import 'checkin_screen.dart';
import 'logger_screen.dart';

class TodayScreen extends StatefulWidget {
  final DecisionTrace trace;

  const TodayScreen({super.key, required this.trace});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  late Future<String> _explanation;

  @override
  void initState() {
    super.initState();
    final controller = context.read<AppController>();
    _explanation = const AiExplainer().dailyExplanation(widget.trace, controller.settings);
  }

  @override
  Widget build(BuildContext context) {
    final trace = widget.trace;
    final plan = trace.plan;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Today'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Redo check-in',
            onPressed: () => _confirmResetToday(context),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ReadinessBadge(bucket: trace.recovery.bucket, score: trace.recovery.compositeScore),
                    const SizedBox(height: 8),
                    Text(
                      plan?.sessionName ?? trace.restReason ?? 'Rest day',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (plan != null) Text('${plan.tier.name} tier - ~${plan.estimatedDurationMin} min'),
                    const SizedBox(height: 12),
                    FutureBuilder<String>(
                      future: _explanation,
                      builder: (context, snap) {
                        if (!snap.hasData) {
                          return const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          );
                        }
                        return Text(snap.data!, style: Theme.of(context).textTheme.bodyMedium);
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (plan != null)
              ...plan.exercises.map((e) => Card(
                    child: ListTile(
                      title: Text(e.name),
                      subtitle: Text(
                        '${e.sets} x ${e.repRange.$1}-${e.repRange.$2} reps'
                        '${e.loadDisplay != null ? ' @ ${e.loadDisplay}' : ''}'
                        '${e.substitutedFrom != null ? ' (sub for ${e.substitutedFrom})' : ''}',
                      ),
                      trailing: Text('RIR ${_rirLabel(e.rirTarget.name)}'),
                    ),
                  )),
            const SizedBox(height: 24),
            if (plan != null)
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => LoggerScreen(plan: plan))),
                  child: const Text('Start session'),
                ),
              ),
            if (trace.candidates.length > 1) ...[
              const SizedBox(height: 24),
              Text('Other options today', style: Theme.of(context).textTheme.titleMedium),
              ...trace.candidates.skip(1).take(2).map(
                    (c) => ListTile(
                      dense: true,
                      title: Text(c.sessionId.name.toUpperCase()),
                      subtitle: Text('score ${c.score}'),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmResetToday(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Redo check-in?'),
        content: const Text(
          "This discards today's check-in and recommendation (readiness numbers, pain flags, "
          'the plan you\'re looking at) so you can enter it again from scratch. '
          "If you haven't logged any sets yet today, nothing else is affected. "
          "If you've already logged part of a session, that workout data is kept either way - "
          'only the check-in itself is reset.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Redo check-in')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    await context.read<AppController>().resetToday();
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const CheckInScreen()));
  }

  String _rirLabel(String name) => switch (name) {
        'rir0' => '0',
        'rir1' => '1',
        'rir2' => '2',
        _ => '3+',
      };
}

/// §4.3's GREEN/YELLOW/RED bucket, made visible - not just a value buried
/// in the trace.
class _ReadinessBadge extends StatelessWidget {
  final ReadinessBucket bucket;
  final double score;

  const _ReadinessBadge({required this.bucket, required this.score});

  Color get _color => switch (bucket) {
        ReadinessBucket.green => Colors.green,
        ReadinessBucket.yellow => Colors.amber.shade800,
        ReadinessBucket.red => Colors.red,
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: _color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(
            '${bucket.name.toUpperCase()} · ${score.round()}',
            style: TextStyle(color: _color, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
