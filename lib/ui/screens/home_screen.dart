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
                  Text(
                    controller.todayTrace == null ? 'No check-in yet today.' : "Today's plan is ready.",
                    style: Theme.of(context).textTheme.titleMedium,
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
                    child: Text(controller.todayTrace == null ? 'Morning check-in' : "View today's plan"),
                  ),
                ],
              ),
      ),
    );
  }
}
