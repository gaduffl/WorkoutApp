import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/ai_explainer.dart';
import '../../models/decision_trace.dart';
import '../../state/app_controller.dart';
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
      appBar: AppBar(title: const Text('Today')),
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

  String _rirLabel(String name) => switch (name) {
        'rir0' => '0',
        'rir1' => '1',
        'rir2' => '2',
        _ => '3+',
      };
}
