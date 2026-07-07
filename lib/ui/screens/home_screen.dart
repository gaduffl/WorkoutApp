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
