import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/pain.dart';
import '../../models/recovery_snapshot.dart';
import '../../state/app_controller.dart';
import 'today_screen.dart';

/// §3 morning check-in: single screen, <=10s to fill in.
class CheckInScreen extends StatefulWidget {
  const CheckInScreen({super.key});

  @override
  State<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends State<CheckInScreen> {
  int? _time;
  int _feel = 3;
  final Map<BodyRegion, PainSeverity> _pain = {};
  final _hrvController = TextEditingController();
  final _rhrController = TextEditingController();
  final _sleepController = TextEditingController();
  bool _submitting = false;

  static const _regionLabels = {
    BodyRegion.lowerBack: 'Lower back',
    BodyRegion.kneeLeft: 'Knee (L)',
    BodyRegion.kneeRight: 'Knee (R)',
    BodyRegion.shoulderLeft: 'Shoulder (L)',
    BodyRegion.shoulderRight: 'Shoulder (R)',
    BodyRegion.elbow: 'Elbow',
    BodyRegion.wrist: 'Wrist',
    BodyRegion.hip: 'Hip',
  };

  @override
  void dispose() {
    _hrvController.dispose();
    _rhrController.dispose();
    _sleepController.dispose();
    super.dispose();
  }

  void _cycleRegion(BodyRegion region) {
    setState(() {
      final current = _pain[region];
      if (current == null) {
        _pain[region] = PainSeverity.mild;
      } else if (current == PainSeverity.mild) {
        _pain[region] = PainSeverity.sharp;
      } else {
        _pain.remove(region);
      }
    });
  }

  Future<void> _submit() async {
    if (_time == null) return;
    setState(() => _submitting = true);
    final controller = context.read<AppController>();
    final now = controller.today();
    final pain = _pain.entries
        .map((e) => PainFlag(region: e.key, severity: e.value, flaggedDate: now))
        .toList();

    RecoverySnapshot? recovery;
    final hrv = double.tryParse(_hrvController.text);
    final rhr = double.tryParse(_rhrController.text);
    final sleep = int.tryParse(_sleepController.text);
    if (hrv != null || rhr != null || sleep != null) {
      recovery = RecoverySnapshot(date: now, hrvRmssd: hrv, restingHr: rhr, sleepScore: sleep);
    }

    final trace = await controller.submitCheckIn(
      timeMinutes: _time!,
      subjective: _feel,
      pain: pain,
      recovery: recovery,
    );

    if (!mounted) return;
    setState(() => _submitting = false);
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => TodayScreen(trace: trace)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ready to plan today?')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Time available today', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [0, 20, 35, 60].map((t) {
                  final label = t == 0 ? 'Rest' : '$t min';
                  return ChoiceChip(
                    label: Text(label),
                    selected: _time == t,
                    onSelected: (_) => setState(() => _time = t),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              Text('How do you feel? (1 = wrecked, 5 = great)', style: Theme.of(context).textTheme.titleMedium),
              Slider(
                value: _feel.toDouble(),
                min: 1,
                max: 5,
                divisions: 4,
                label: '$_feel',
                onChanged: (v) => setState(() => _feel = v.round()),
              ),
              const SizedBox(height: 16),
              Text('Pain anywhere? (tap: mild -> sharp -> clear)', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _regionLabels.entries.map((e) {
                  final severity = _pain[e.key];
                  final color = severity == null
                      ? null
                      : (severity == PainSeverity.mild ? Colors.orange.shade200 : Colors.red.shade300);
                  return ActionChip(
                    label: Text(severity == null ? e.value : '${e.value} (${severity.name})'),
                    backgroundColor: color,
                    onPressed: () => _cycleRegion(e.key),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              Text('Recovery (optional - pre-filled from Oura when connected)',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _hrvController,
                      decoration: const InputDecoration(labelText: 'HRV (rMSSD)'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _rhrController,
                      decoration: const InputDecoration(labelText: 'Resting HR'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _sleepController,
                      decoration: const InputDecoration(labelText: 'Sleep score'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: (_time == null || _submitting) ? null : _submit,
                  child: _submitting
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Get my plan'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
