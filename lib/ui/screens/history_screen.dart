import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/repository.dart';
import '../../models/floor_category.dart';
import '../../models/session_log.dart';
import '../../state/app_controller.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<Repository>();
    final controller = context.read<AppController>();
    final since = controller.today().subtract(const Duration(days: 28));

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: FutureBuilder<List<SessionLog>>(
        future: repo.loadSessionLogsSince(since),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final logs = snap.data!..sort((a, b) => b.date.compareTo(a.date));
          final last7 = controller.today().subtract(const Duration(days: 7));
          final strengthCount =
              logs.where((l) => l.countsAs.contains(FloorCategory.strength) && l.countsTowardQueueAndFloor && !l.date.isBefore(last7)).length;
          final intensityCount =
              logs.where((l) => l.countsAs.contains(FloorCategory.intensity) && l.countsTowardQueueAndFloor && !l.date.isBefore(last7)).length;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Rolling 7-day floor', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text('Strength: $strengthCount / ${controller.settings.weeklyFloor[FloorCategory.strength]}'),
                      Text('Intensity: $intensityCount / ${controller.settings.weeklyFloor[FloorCategory.intensity]}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (logs.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No sessions logged yet.')),
              ...logs.map((l) => Card(
                    child: ListTile(
                      title: Text('${l.templateId.name.toUpperCase()} - ${l.tier.name}'),
                      subtitle: Text(
                        '${l.date.toLocal().toString().split(' ').first} - '
                        '${l.completedWorkSets}/${l.plannedWorkSets} sets - ${l.durationMinutes} min'
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
