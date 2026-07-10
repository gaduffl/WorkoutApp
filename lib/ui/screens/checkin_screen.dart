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
  final Map<BodyRegion, Set<PainTag>> _painTags = {};
  final _hrvController = TextEditingController();
  final _rhrController = TextEditingController();
  final _sleepController = TextEditingController();
  bool _submitting = false;
  bool _ouraSyncing = false;
  bool _ouraSyncFailed = false;
  bool _ouraPrefilled = false;

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

  static const _tagLabels = {
    PainTag.radiating: 'Radiating',
    PainTag.numbness: 'Numbness',
    PainTag.tingling: 'Tingling',
  };

  @override
  void initState() {
    super.initState();
    _syncOura();
  }

  Future<void> _syncOura() async {
    final controller = context.read<AppController>();
    if (!controller.settings.oura.isConnected) return;
    setState(() => _ouraSyncing = true);
    final snapshot = await controller.fetchOuraRecovery(controller.today());
    if (!mounted) return;
    setState(() {
      _ouraSyncing = false;
      if (snapshot == null) {
        _ouraSyncFailed = true;
        return;
      }
      _ouraPrefilled = true;
      if (snapshot.hrvRmssd != null) _hrvController.text = snapshot.hrvRmssd!.toStringAsFixed(0);
      if (snapshot.restingHr != null) _rhrController.text = snapshot.restingHr!.toStringAsFixed(0);
      if (snapshot.sleepScore != null) _sleepController.text = snapshot.sleepScore!.toString();
    });
  }

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
        _painTags.remove(region);
      }
    });
  }

  void _togglePainTag(BodyRegion region, PainTag tag, bool selected) {
    setState(() {
      final tags = _painTags.putIfAbsent(region, () => <PainTag>{});
      selected ? tags.add(tag) : tags.remove(tag);
      if (tags.isEmpty) _painTags.remove(region);
    });
  }

  Future<void> _submit() async {
    if (_time == null || _submitting) return;
    final controller = context.read<AppController>();
    final now = controller.today();
    final pain = _pain.entries
        .map((e) => PainFlag(
              region: e.key,
              severity: e.value,
              flaggedDate: now,
              tags: Set.of(_painTags[e.key] ?? const <PainTag>{}),
            ))
        .toList();

    RecoverySnapshot? recovery;
    final hrvText = _hrvController.text.trim();
    final rhrText = _rhrController.text.trim();
    final sleepText = _sleepController.text.trim();
    final hrv = hrvText.isEmpty ? null : double.tryParse(hrvText);
    final rhr = rhrText.isEmpty ? null : double.tryParse(rhrText);
    final sleep = sleepText.isEmpty ? null : int.tryParse(sleepText);
    final invalidMessage = hrvText.isNotEmpty && (hrv == null || !hrv.isFinite || hrv <= 0)
        ? 'HRV must be a positive number.'
        : rhrText.isNotEmpty && (rhr == null || !rhr.isFinite || rhr <= 0)
            ? 'Resting HR must be a positive number.'
            : sleepText.isNotEmpty && (sleep == null || sleep < 0 || sleep > 100)
                ? 'Sleep score must be a whole number from 0 to 100.'
                : null;
    if (invalidMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(invalidMessage)));
      return;
    }
    if (hrv != null || rhr != null || sleep != null) {
      recovery = RecoverySnapshot(date: now, hrvRmssd: hrv, restingHr: rhr, sleepScore: sleep);
    }

    setState(() => _submitting = true);

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
              if (_pain.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'Add any warning symptoms (optional)',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                ..._pain.keys.map((region) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 92,
                            child: Text(_regionLabels[region]!, style: Theme.of(context).textTheme.bodySmall),
                          ),
                          Expanded(
                            child: Wrap(
                              spacing: 6,
                              children: _tagLabels.entries
                                  .map((tag) => FilterChip(
                                        visualDensity: VisualDensity.compact,
                                        label: Text(tag.value),
                                        selected: _painTags[region]?.contains(tag.key) ?? false,
                                        onSelected: (selected) => _togglePainTag(region, tag.key, selected),
                                      ))
                                  .toList(),
                            ),
                          ),
                        ],
                      ),
                    )),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text('Recovery (optional)', style: Theme.of(context).textTheme.titleMedium),
                  ),
                  if (_ouraSyncing)
                    const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
              if (_ouraPrefilled)
                Text('Pre-filled from Oura - edit any field if it looks off.',
                    style: Theme.of(context).textTheme.bodySmall)
              else if (_ouraSyncFailed)
                Text('Oura data unavailable today - enter manually.',
                    style: TextStyle(color: Theme.of(context).colorScheme.error))
              else
                Text('Manual entry (connect Oura in Settings to pre-fill this)',
                    style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _hrvController,
                      decoration: const InputDecoration(labelText: 'HRV (rMSSD)'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _rhrController,
                      decoration: const InputDecoration(labelText: 'Resting HR'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
