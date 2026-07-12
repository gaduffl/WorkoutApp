import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_controller.dart';
import 'checkin_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';
import 'today_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('MorningCoach'),
        actions: [
          IconButton(
            icon: controller.travelModeChanging
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    controller.settings.travelMode ? Icons.luggage : Icons.luggage_outlined,
                    color: controller.settings.travelMode ? Theme.of(context).colorScheme.primary : null,
                  ),
            tooltip: controller.settings.travelMode ? 'End travel mode' : 'Start travel mode',
            onPressed: controller.travelModeChanging ? null : () async {
              final enabled = !controller.settings.travelMode;
              try {
                await controller.setTravelMode(enabled);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(enabled ? 'Travel mode enabled' : 'Travel mode disabled')),
                );
              } catch (error) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not change travel mode: $error')),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Center(
        child: controller.loading
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (controller.settings.travelMode) ...[
                    Card(
                      color: Theme.of(context).colorScheme.tertiaryContainer,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.luggage),
                            SizedBox(width: 8),
                            Text('Travel mode · no equipment'),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (controller.sessionDoneToday)
                    const Icon(Icons.check_circle, color: Colors.green, size: 48),
                  Text(
                    controller.todayTrace == null
                        ? 'No check-in yet today.'
                        : controller.sessionDoneToday
                            ? "Today's session is done ✅"
                            : "Today's plan is ready.",
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () {
                      final trace = controller.todayTrace;
                      if (trace != null) {
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => TodayScreen(trace: trace)));
                      } else {
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CheckInScreen()));
                      }
                    },
                    child: Text(controller.todayTrace == null
                        ? 'Morning check-in'
                        : controller.sessionDoneToday
                            ? "View today's summary"
                            : "View today's plan"),
                  ),
                ],
              ),
      ),
    );
  }
}
