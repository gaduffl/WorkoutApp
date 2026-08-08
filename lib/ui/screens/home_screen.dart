import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/cardio_engine.dart';
import '../../models/lower_back_recovery.dart';
import '../../models/session_type.dart';
import '../../state/app_controller.dart';
import '../widgets/cardio_widgets.dart';
import 'checkin_screen.dart';
import 'history_screen.dart';
import 'insights_screen.dart';
import 'settings_screen.dart';
import 'today_screen.dart';

String homeTodayStatus({
  required bool hasTrace,
  required bool sessionLogged,
  required bool sessionDone,
}) {
  if (!hasTrace) return 'No check-in yet today.';
  if (sessionDone) return "Today's session is done ✅";
  if (sessionLogged) return "Today's workout attempt is saved.";
  return "Today's plan is ready.";
}

String homeTodayActionLabel({
  required bool hasTrace,
  required bool sessionLogged,
  required bool sessionDone,
}) {
  if (!hasTrace) return 'Morning check-in';
  if (sessionDone || sessionLogged) return "View today's summary";
  return "View today's plan";
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loggingUnplannedRehit = false;

  Future<void> _recordLowerBackMorningResponse(
    LowerBackSymptomResponse response,
  ) async {
    await context
        .read<AppController>()
        .recordLowerBackNextMorningResponse(response);
    if (!mounted) return;
    final message = response == LowerBackSymptomResponse.worse
        ? 'Dose stepped back. Stop and seek care for new spreading pain, numbness, tingling, weakness, or bladder/bowel changes.'
        : 'Next-morning response saved.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _logUnplannedRehit() async {
    if (_loggingUnplannedRehit) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log unplanned REHIT?'),
        content: const Text(
          'Use this only if you have already completed the fixed CAROL REHIT '
          'Intense preset. The saved attempt will appear in history and count '
          'toward high-intensity recovery timing. It will not complete or '
          "replace today's planned workout.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final controller = context.read<AppController>();
    try {
      final prescription = const CardioEngine().resolvePrescription(
        sessionId: SessionTypeId.s7,
        persistedPrescription: null,
        durationMinutes: sessionTypes[SessionTypeId.s7]!.fullDurationMin,
        heartRateMaxBpm: controller.settings.hrMax,
      );
      final completion = await showCardioCompletionDialog(
        context,
        prescription: prescription,
        title: 'Log completed unplanned CAROL REHIT',
      );
      if (completion == null || !mounted) return;

      setState(() => _loggingUnplannedRehit = true);
      await controller.logUnplannedRehit(completion: completion);
      if (!mounted) return;
      final message = completion.meetsCreditableDose
          ? 'Unplanned CAROL REHIT logged — full intensity credit ✓'
          : 'Unplanned CAROL REHIT attempt saved — below the qualifying intensity dose';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not log unplanned REHIT: $error')),
      );
    } finally {
      if (mounted) setState(() => _loggingUnplannedRehit = false);
    }
  }

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
            tooltip: 'History',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryScreen())),
          ),
          IconButton(
            key: const Key('home-open-insights'),
            icon: const Icon(Icons.query_stats),
            tooltip: 'Training insights',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const InsightsScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: controller.loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (controller.lowerBackRecovery.active) ...[
                              Card(
                                key: const Key('home-lower-back-recovery'),
                                color: Theme.of(context)
                                    .colorScheme
                                    .secondaryContainer,
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.health_and_safety),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              'Lower-back recovery mode',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(controller
                                          .lowerBackRecovery.stageLabel),
                                      Text(controller
                                          .lowerBackRecovery.targetLabel),
                                      const SizedBox(height: 4),
                                      const Text(
                                        'Loaded deadlift progression is paused.',
                                      ),
                                      if (controller
                                          .lowerBackMorningResponseDue) ...[
                                        const SizedBox(height: 12),
                                        const Text(
                                          'Compared with before yesterday\'s recovery work, how does your lower back feel this morning?',
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 8,
                                          children: [
                                            OutlinedButton(
                                              onPressed: () =>
                                                  _recordLowerBackMorningResponse(
                                                LowerBackSymptomResponse.worse,
                                              ),
                                              child: const Text('Worse'),
                                            ),
                                            OutlinedButton(
                                              onPressed: () =>
                                                  _recordLowerBackMorningResponse(
                                                LowerBackSymptomResponse
                                                    .unchanged,
                                              ),
                                              child: const Text('Same'),
                                            ),
                                            FilledButton(
                                              onPressed: () =>
                                                  _recordLowerBackMorningResponse(
                                                LowerBackSymptomResponse.better,
                                              ),
                                              child: const Text('Better'),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
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
                            if (controller.sessionDoneToday || controller.sessionLoggedToday)
                              Icon(
                                controller.sessionDoneToday
                                    ? Icons.check_circle
                                    : Icons.check_circle_outline,
                                color: Colors.green,
                                size: 48,
                              ),
                            Text(
                              homeTodayStatus(
                                hasTrace: controller.todayTrace != null,
                                sessionLogged: controller.sessionLoggedToday,
                                sessionDone: controller.sessionDoneToday,
                              ),
                              style: Theme.of(context).textTheme.titleMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () {
                                final trace = controller.todayTrace;
                                if (trace != null) {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => TodayScreen(trace: trace),
                                    ),
                                  );
                                } else {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => const CheckInScreen(),
                                    ),
                                  );
                                }
                              },
                              child: Text(
                                homeTodayActionLabel(
                                  hasTrace: controller.todayTrace != null,
                                  sessionLogged: controller.sessionLoggedToday,
                                  sessionDone: controller.sessionDoneToday,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              key: const Key('home-log-unplanned-rehit'),
                              onPressed: _loggingUnplannedRehit
                                  ? null
                                  : _logUnplannedRehit,
                              icon: _loggingUnplannedRehit
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.add_chart),
                              label: const Text('Log unplanned REHIT'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
