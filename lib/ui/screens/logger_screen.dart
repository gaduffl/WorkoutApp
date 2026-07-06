import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/session_templates.dart';
import '../../models/plan.dart';
import '../../models/session_type.dart';
import '../../models/set_log.dart';
import '../../state/app_controller.dart';

/// §11.3: one exercise at a time, big steppers, RIR buttons, pain button,
/// rest timer, "wrap up" button.
class LoggerScreen extends StatefulWidget {
  final SessionPlan plan;

  const LoggerScreen({super.key, required this.plan});

  @override
  State<LoggerScreen> createState() => _LoggerScreenState();
}

class _LoggerScreenState extends State<LoggerScreen> {
  int _exerciseIndex = 0;
  int _setNumber = 1;
  final List<SetLog> _logged = [];
  double _weight = 0;
  int _reps = 8;
  Rir _rir = Rir.rir2;
  bool _painFlag = false;
  Timer? _restTimer;
  int _restSecondsLeft = 0;
  final _stopwatch = Stopwatch()..start();

  PlannedExercise get _exercise => widget.plan.exercises[_exerciseIndex];

  @override
  void initState() {
    super.initState();
    _weight = _exercise.loadTotal ?? 0;
    _reps = _exercise.repRange.$1;
  }

  @override
  void dispose() {
    _restTimer?.cancel();
    super.dispose();
  }

  void _startRest() {
    final compound = _exercise.repRange.$1 <= 10;
    _restSecondsLeft = compound ? 90 : 60;
    _restTimer?.cancel();
    _restTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_restSecondsLeft <= 0) {
        t.cancel();
        return;
      }
      setState(() => _restSecondsLeft -= 1);
    });
  }

  void _logSet() {
    setState(() {
      _logged.add(SetLog(
        trackKey: _exercise.trackKey,
        pattern: _exercise.pattern,
        exerciseName: _exercise.name,
        weight: _weight,
        reps: _reps,
        rir: _rir,
        painFlag: _painFlag,
        isWarmup: _exercise.isWarmup,
        timestamp: DateTime.now(),
      ));
      _painFlag = false;
      if (_setNumber < _exercise.sets) {
        _setNumber += 1;
        if (!_exercise.isWarmup) _startRest(); // warm-up rest is <= 60 s, self-paced
      } else if (_exerciseIndex < widget.plan.exercises.length - 1) {
        _exerciseIndex += 1;
        _setNumber = 1;
        _weight = _exercise.loadTotal ?? 0;
        _reps = _exercise.repRange.$1;
      }
    });
  }

  Future<void> _finish({bool wrapUp = false}) async {
    final controller = context.read<AppController>();

    // §2.1: S2's intensity credit exists only if the optional REHIT finisher
    // was actually completed — ask when the template offers one.
    var rehitDone = false;
    final offersFinisher = sessionTemplates[widget.plan.sessionId]?.hasOptionalRehitFinisher ?? false;
    if (!wrapUp && offersFinisher && widget.plan.tier == SessionTier.extended && mounted) {
      rehitDone = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('REHIT finisher'),
              content: const Text('Did you do the 8-min REHIT finisher? (That is what earns the intensity credit.)'),
              actions: [
                TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Skipped')),
                FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Done')),
              ],
            ),
          ) ??
          false;
    }
    if (!mounted) return;

    await controller.completeSession(
      widget.plan,
      _logged,
      durationMinutes: (_stopwatch.elapsed.inMinutes).clamp(1, 999),
      rehitFinisherCompleted: rehitDone,
    );
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final e = _exercise;
    return Scaffold(
      appBar: AppBar(
        title: Text('${e.name} - set $_setNumber/${e.sets}'),
        actions: [
          TextButton(
            onPressed: () => _finish(wrapUp: true),
            child: const Text('Wrap up', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text('Target: ${e.repRange.$1}-${e.repRange.$2} reps${e.loadDisplay != null ? ' @ ${e.loadDisplay}' : ''}'),
              const SizedBox(height: 24),
              _stepperRow('Weight (lb)', _weight, (d) => setState(() => _weight = (_weight + d).clamp(0, 500))),
              _stepperRow('Reps', _reps.toDouble(), (d) => setState(() => _reps = (_reps + d.toInt()).clamp(0, 50)),
                  isInt: true),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: Rir.values.map((r) {
                  return ChoiceChip(
                    label: Text(_rirLabel(r)),
                    selected: _rir == r,
                    onSelected: (_) => setState(() => _rir = r),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              FilterChip(
                label: const Text('Pain on this set'),
                selected: _painFlag,
                onSelected: (v) => setState(() => _painFlag = v),
              ),
              if (_restSecondsLeft > 0) ...[
                const SizedBox(height: 16),
                Text('Rest: $_restSecondsLeft s', style: Theme.of(context).textTheme.titleLarge),
              ],
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: _logSet, child: const Text('Log set')),
              ),
              const SizedBox(height: 8),
              if (_exerciseIndex == widget.plan.exercises.length - 1 && _setNumber == e.sets)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(onPressed: () => _finish(), child: const Text('Finish session')),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepperRow(String label, double value, void Function(double) onDelta, {bool isInt = false}) {
    final step = isInt ? 1.0 : 5.0;
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(onPressed: () => onDelta(-step), icon: const Icon(Icons.remove_circle_outline)),
        Text(isInt ? value.toInt().toString() : value.toStringAsFixed(0), style: Theme.of(context).textTheme.titleLarge),
        IconButton(onPressed: () => onDelta(step), icon: const Icon(Icons.add_circle_outline)),
      ],
    );
  }

  String _rirLabel(Rir r) => switch (r) {
        Rir.rir0 => 'RIR 0',
        Rir.rir1 => 'RIR 1',
        Rir.rir2 => 'RIR 2',
        Rir.rir3plus => 'RIR 3+',
      };
}
