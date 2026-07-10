import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/session_templates.dart';
import '../../models/movement_pattern.dart';
import '../../models/plan.dart';
import '../../models/session_type.dart';
import '../../models/set_log.dart';
import '../../state/app_controller.dart';

/// §11.3: one exercise at a time, big steppers, RIR buttons, pain button,
/// rest timer, "wrap up" button. Weight steps follow the exercise's real
/// PowerBlock totals (§2.6); superset pairs (§2.5) are alternated set-by-set
/// with a toggle to run them as straight sets instead.
class LoggerScreen extends StatefulWidget {
  final SessionPlan plan;

  const LoggerScreen({super.key, required this.plan});

  @override
  State<LoggerScreen> createState() => _LoggerScreenState();
}

/// One logged set in the play order: which plan exercise, which set number,
/// and whether a rest timer should start after it.
class _Step {
  final int exIdx;
  final int setNumber;
  final bool restAfter;
  const _Step(this.exIdx, this.setNumber, {this.restAfter = false});
}

class _LoggerScreenState extends State<LoggerScreen> {
  late List<_Step> _steps;
  int _current = 0;
  bool _superset = true;

  final List<SetLog> _logged = [];
  final Set<String> _loggedKeys = {}; // 'exIdx:setNumber' of completed steps
  final Map<int, double> _weightByExercise = {}; // per plan-exercise working weight
  int _reps = 8;
  Rir _rir = Rir.rir2;
  bool _painFlag = false;
  bool _finishing = false;
  Timer? _restTimer;
  int _restSecondsLeft = 0;
  final _stopwatch = Stopwatch()..start();

  List<PlannedExercise> get _ex => widget.plan.exercises;
  PlannedExercise get _exercise => _ex[_steps[_current].exIdx];
  bool get _hasSupersets => _ex.any((e) => !e.isWarmup && e.supersetGroup != null);

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < _ex.length; i++) {
      _weightByExercise[i] = _ex[i].loadTotal ?? 0;
    }
    _steps = _buildSteps(_superset);
    _syncSetInputs();
  }

  @override
  void dispose() {
    _restTimer?.cancel();
    super.dispose();
  }

  // ---- play-order construction ----

  List<_Step> _buildSteps(bool superset) {
    // Group each work exercise with the warm-up entries that precede it.
    final units = <({int workIdx, List<int> warmups, int? group})>[];
    final pending = <int>[];
    for (var i = 0; i < _ex.length; i++) {
      if (_ex[i].isWarmup) {
        pending.add(i);
      } else {
        units.add((workIdx: i, warmups: List.of(pending), group: _ex[i].supersetGroup));
        pending.clear();
      }
    }

    final steps = <_Step>[];
    var u = 0;
    while (u < units.length) {
      final unit = units[u];
      if (superset && unit.group != null) {
        final group = [unit];
        var v = u + 1;
        while (v < units.length && units[v].group == unit.group) {
          group.add(units[v]);
          v++;
        }
        for (final m in group) {
          for (final w in m.warmups) {
            steps.add(_Step(w, 1));
          }
        }
        final maxSets = group.map((m) => _ex[m.workIdx].sets).fold(0, (a, b) => a > b ? a : b);
        for (var s = 1; s <= maxSets; s++) {
          final round = [for (final m in group) if (s <= _ex[m.workIdx].sets) m.workIdx];
          for (var k = 0; k < round.length; k++) {
            // rest after the last exercise of the round (superset partner fills the gap)
            steps.add(_Step(round[k], s, restAfter: k == round.length - 1));
          }
        }
        u = v;
      } else {
        for (final w in unit.warmups) {
          steps.add(_Step(w, 1));
        }
        for (var s = 1; s <= _ex[unit.workIdx].sets; s++) {
          steps.add(_Step(unit.workIdx, s, restAfter: true)); // straight sets rest after each
        }
        u++;
      }
    }
    // no rest after the very last step
    if (steps.isNotEmpty) {
      final last = steps.removeLast();
      steps.add(_Step(last.exIdx, last.setNumber));
    }
    return steps;
  }

  void _toggleSuperset(bool on) {
    setState(() {
      _superset = on;
      // Rebuild remaining steps; keep already-logged sets. Jump to the first
      // step that hasn't been logged yet.
      _steps = _buildSteps(on);
      _current = _steps.indexWhere((st) => !_loggedKeys.contains('${st.exIdx}:${st.setNumber}'));
      if (_current < 0) _current = _steps.length - 1;
      _restTimer?.cancel();
      _restSecondsLeft = 0;
      _syncSetInputs();
    });
  }

  void _syncSetInputs() {
    _reps = _exercise.repRange.$1;
    _rir = Rir.rir2;
    _painFlag = false;
  }

  // ---- weight stepper snapping to PowerBlock totals (§2.6) ----

  void _stepWeight(int dir) {
    final idx = _steps[_current].exIdx;
    final steps = _ex[idx].loadSteps;
    final cur = _weightByExercise[idx] ?? 0;
    double next;
    if (steps == null || steps.isEmpty) {
      next = (cur + dir * 5).clamp(0, 500); // backpack/free entry
    } else if (dir > 0) {
      next = steps.firstWhere((s) => s > cur + 0.001, orElse: () => cur);
    } else {
      final below = steps.where((s) => s < cur - 0.001);
      next = below.isEmpty ? cur : below.last;
    }
    setState(() => _weightByExercise[idx] = next);
  }

  void _startRest(bool compound) {
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

  Future<void> _logSet() async {
    if (_finishing) return;
    final step = _steps[_current];
    final ex = _ex[step.exIdx];
    final wasLast = _current == _steps.length - 1;
    final log = SetLog(
      trackKey: ex.trackKey,
      pattern: ex.pattern,
      exerciseName: ex.name,
      weight: _weightByExercise[step.exIdx] ?? 0,
      reps: _reps,
      rir: _rir,
      painFlag: _painFlag,
      isWarmup: ex.isWarmup,
      timestamp: DateTime.now(),
    );
    setState(() {
      _logged.add(log);
      _loggedKeys.add('${step.exIdx}:${step.setNumber}');
      // Logging ends the previous rest — always reset the timer, then start
      // a fresh one only if this set is followed by rest.
      _restTimer?.cancel();
      _restSecondsLeft = 0;
      if (!wasLast && step.restAfter && !ex.isWarmup) {
        _startRest(ex.pattern.patternClass == PatternClass.compound);
      }
      if (!wasLast) {
        _current++;
        _syncSetInputs();
      }
    });
    // Logging the final set finishes the workout automatically.
    if (wasLast) await _finish();
  }

  Future<void> _finish({bool wrapUp = false}) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    final controller = context.read<AppController>();

    try {
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
        durationMinutes: _stopwatch.elapsed.inMinutes.clamp(1, 999),
        rehitFinisherCompleted: rehitDone,
      );
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = _steps[_current];
    final e = _exercise;
    final partner = _supersetPartnerName(step);
    final isLast = _current == _steps.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text('${e.name}${e.isWarmup ? '' : ' - set ${step.setNumber}/${e.sets}'}'),
        actions: [
          TextButton(
            onPressed: _finishing ? null : () => _finish(wrapUp: true),
            child: const Text('Wrap up', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      if (_hasSupersets)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Superset mode'),
                          subtitle: Text(_superset
                              ? 'Alternate the paired exercises, rest after each pair'
                              : 'Run every exercise as straight sets'),
                          value: _superset,
                          onChanged: _toggleSuperset,
                        ),
                      if (e.isWarmup)
                        const Chip(label: Text('Warm-up set'))
                      else if (_superset && partner != null)
                        Chip(
                          avatar: const Icon(Icons.swap_vert, size: 18),
                          label: Text('Superset — next: $partner'),
                        ),
                      const SizedBox(height: 12),
                      Text(
                        'Target: ${e.repRange.$1}-${e.repRange.$2} reps'
                        '${e.loadDisplay != null ? ' @ ${e.loadDisplay}' : ''}',
                        style: Theme.of(context).textTheme.bodyLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      if (e.loadTotal != null || e.loadSteps != null)
                        _weightStepper()
                      else
                        const Text('Bodyweight', style: TextStyle(fontWeight: FontWeight.bold)),
                      _repsStepper(),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        alignment: WrapAlignment.center,
                        children: Rir.values
                            .map((r) => ChoiceChip(
                                  label: Text(_rirLabel(r)),
                                  selected: _rir == r,
                                  onSelected: (_) => setState(() => _rir = r),
                                ))
                            .toList(),
                      ),
                      const SizedBox(height: 12),
                      Tooltip(
                        message: 'Stops progression for this exercise today. '
                            'Identify persistent pain at your next check-in.',
                        child: FilterChip(
                          label: const Text('Pain — stop progression today'),
                          selected: _painFlag,
                          onSelected: (v) => setState(() => _painFlag = v),
                        ),
                      ),
                      if (_painFlag)
                        Text(
                          'Persistent pain? Identify its location and symptoms at your next check-in.',
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      if (_restSecondsLeft > 0) ...[
                        const SizedBox(height: 16),
                        Text('Rest: $_restSecondsLeft s', style: Theme.of(context).textTheme.headlineSmall),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _finishing ? null : _logSet,
                  child: Text(isLast ? 'Log set & finish' : 'Log set'),
                ),
              ),
              if (!isLast) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _finishing ? null : () => _finish(),
                    child: const Text('Finish early'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String? _supersetPartnerName(_Step step) {
    final group = _ex[step.exIdx].supersetGroup;
    if (group == null) return null;
    // find the next step in a different exercise sharing the group
    for (var i = _current + 1; i < _steps.length; i++) {
      final other = _steps[i];
      if (other.exIdx != step.exIdx && _ex[other.exIdx].supersetGroup == group) {
        return _ex[other.exIdx].name;
      }
    }
    return null;
  }

  Widget _weightStepper() {
    final w = _weightByExercise[_steps[_current].exIdx] ?? 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(width: 90, child: Text('Weight')),
        IconButton.filledTonal(onPressed: () => _stepWeight(-1), icon: const Icon(Icons.remove)),
        SizedBox(
          width: 96,
          child: Text('${w.toStringAsFixed(0)} lb',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
        ),
        IconButton.filledTonal(onPressed: () => _stepWeight(1), icon: const Icon(Icons.add)),
      ],
    );
  }

  Widget _repsStepper() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(width: 90, child: Text('Reps')),
        IconButton.filledTonal(
            onPressed: () => setState(() => _reps = (_reps - 1).clamp(0, 50)), icon: const Icon(Icons.remove)),
        SizedBox(
          width: 96,
          child: Text('$_reps', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
        ),
        IconButton.filledTonal(
            onPressed: () => setState(() => _reps = (_reps + 1).clamp(0, 50)), icon: const Icon(Icons.add)),
      ],
    );
  }

  String _rirLabel(Rir r) => switch (r) {
        Rir.rir0 => 'RIR 0',
        Rir.rir1 => 'RIR 1',
        Rir.rir2 => 'RIR 2',
        Rir.rir3plus => 'RIR 3+',
        Rir.rir4plus => 'RIR 4+',
      };
}
