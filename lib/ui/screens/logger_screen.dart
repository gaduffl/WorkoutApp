import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/cardio_engine.dart';
import '../../engine/equipment_engine.dart';
import '../../engine/session_templates.dart';
import '../../engine/strength_duration_engine.dart';
import '../../models/cardio_protocol.dart';
import '../../models/exercise_metric.dart';
import '../../models/equipment.dart';
import '../../models/plan.dart';
import '../../models/session_type.dart';
import '../../models/set_log.dart';
import '../../state/app_controller.dart';
import '../widgets/cardio_widgets.dart';
import '../widgets/progression_panel.dart';

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
  int _value = 8;
  Rir _rir = Rir.rir2;
  bool _painFlag = false;
  bool _finishing = false;
  Timer? _restTimer;
  int _restSecondsLeft = 0;
  Timer? _holdTimer;
  int _holdSecondsLeft = 0;
  int _holdTargetSeconds = 0;
  bool _holdRunning = false;
  bool _holdTimerUsed = false;
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
    _holdTimer?.cancel();
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
    _holdTimer?.cancel();
    _holdRunning = false;
    _value = _exercise.suggestedValue ?? _exercise.targetRange.$1;
    _holdSecondsLeft = _value;
    _holdTargetSeconds = _value;
    _holdTimerUsed = false;
    _rir = _exercise.rirTarget;
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

  void _startRest(int seconds) {
    _restSecondsLeft = seconds;
    _restTimer?.cancel();
    _restTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_restSecondsLeft <= 0) {
        t.cancel();
        return;
      }
      setState(() => _restSecondsLeft -= 1);
    });
  }

  int? _restSecondsAfter(_Step step, PlannedExercise exercise) {
    if (exercise.isWarmup) {
      // General/ATG preparation is a continuous minute block and transitions
      // directly into the load ramp. Generated load ramps and later-compound
      // feeders are rep-based, loaded warm-ups whose duration budget includes
      // 45 seconds before the next step.
      final isLoadedRepWarmup =
          exercise.metric == ExerciseMetric.reps && exercise.loadTotal != null;
      return isLoadedRepWarmup
          ? StrengthDurationEstimator.loadWarmupRestSeconds
          : null;
    }
    if (!step.restAfter) return null;
    return exercise.isCompoundWork ? 90 : 60;
  }

  void _toggleHoldTimer() {
    if (_holdRunning) {
      _holdTimer?.cancel();
      setState(() => _holdRunning = false);
      return;
    }
    setState(() {
      if (_holdSecondsLeft <= 0 || !_holdTimerUsed) {
        _holdSecondsLeft = _value;
        _holdTargetSeconds = _value;
      }
      _holdTimerUsed = true;
      _holdRunning = true;
    });
    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_holdSecondsLeft <= 1) {
        timer.cancel();
        setState(() {
          _holdSecondsLeft = 0;
          _holdRunning = false;
        });
      } else {
        setState(() => _holdSecondsLeft -= 1);
      }
    });
  }

  void _resetHoldTimer() {
    _holdTimer?.cancel();
    setState(() {
      _holdRunning = false;
      _holdSecondsLeft = _value;
      _holdTargetSeconds = _value;
      _holdTimerUsed = false;
    });
  }

  int get _loggedValue {
    if (_exercise.metric != ExerciseMetric.seconds || !_holdTimerUsed) {
      return _value;
    }
    return (_holdTargetSeconds - _holdSecondsLeft)
        .clamp(0, _holdTargetSeconds)
        .toInt();
  }

  void _stepValue(int direction) {
    final step = _exercise.metric == ExerciseMetric.seconds ? 5 : 1;
    final max = switch (_exercise.metric) {
      ExerciseMetric.reps => 50,
      ExerciseMetric.seconds => 600,
      ExerciseMetric.minutes => 120,
    };
    final next = (_value + direction * step).clamp(0, max).toInt();
    _holdTimer?.cancel();
    setState(() {
      _value = next;
      if (_exercise.metric == ExerciseMetric.seconds) {
        // A manual target change intentionally leaves countdown mode. The
        // selected value becomes an explicit manual result until Start hold
        // is pressed again.
        _holdRunning = false;
        _holdTimerUsed = false;
        _holdTargetSeconds = next;
        _holdSecondsLeft = next;
      }
    });
  }

  Future<void> _logSet() async {
    if (_finishing) return;
    final completedValue = _loggedValue;
    if (completedValue <= 0) return;
    final step = _steps[_current];
    final ex = _ex[step.exIdx];
    final wasLast = _current == _steps.length - 1;
    final restSeconds = wasLast ? null : _restSecondsAfter(step, ex);
    final log = SetLog(
      trackKey: ex.trackKey,
      pattern: ex.pattern,
      exerciseName: ex.name,
      weight: _weightByExercise[step.exIdx] ?? 0,
      metric: ex.metric,
      value: completedValue,
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
      _holdTimer?.cancel();
      _holdRunning = false;
      _holdSecondsLeft = 0;
      if (restSeconds != null) _startRest(restSeconds);
      if (!wasLast) {
        _current++;
        _syncSetInputs();
      }
    });
    // Logging the final set finishes the workout automatically.
    if (wasLast) await _finish();
  }

  Future<bool> _confirmFinishEarly() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Finish workout early?'),
        content: const Text(
          'End the session now and save completed sets.\n'
          'Unperformed exercises will not advance progression.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('End workout'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _finish({bool wrapUp = false}) async {
    if (_finishing) return;
    setState(() => _finishing = true);
    final controller = context.read<AppController>();

    try {
      CardioCompletion? rehitCompletion;
      // A partial dose is evaluated separately by the shared >=50% gate.
      // `endedEarly` records only the user's explicit Wrap up action.
      final endedEarly = wrapUp;
      final offersFinisher =
          widget.plan.optionalRehitFinisherReserved &&
          sessionTemplates[widget.plan.sessionId]?.hasOptionalRehitFinisher ==
              true &&
          widget.plan.tier == SessionTier.extended &&
          controller
              .rehitFinisherEligibility(
                widget.plan,
                _logged,
                endedEarly: endedEarly,
              )
              .eligible;
      if (offersFinisher && mounted) {
        final prescription = const CardioEngine().prescriptionFor(
          sessionId: SessionTypeId.s7,
          durationMinutes:
              sessionTypes[SessionTypeId.s7]!.fullDurationMin,
          heartRateMaxBpm: controller.settings.hrMax,
        );
        rehitCompletion = await showCardioCompletionDialog(
          context,
          prescription: prescription,
          title: 'Log optional REHIT finisher',
        );
      }
      if (!mounted) return;

      await controller.completeSession(
        widget.plan,
        _logged,
        durationMinutes: _stopwatch.elapsed.inMinutes.clamp(1, 999),
        rehitFinisherCompletion: rehitCompletion,
        endedEarly: endedEarly,
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
    // Logger tests and legacy callers may render a plan outside the normal
    // app provider. New plans resolve against the current equipment config;
    // old plans safely retain their total-only display when it is absent.
    final controller = Provider.of<AppController?>(context, listen: false);
    final currentLoad = _weightByExercise[step.exIdx] ?? 0;
    final currentLoadDisplay = _loadDisplay(
      e,
      currentLoad,
      controller?.settings.equipment,
      setNumber: step.setNumber,
    );
    final partner = _supersetPartnerName(step);
    final isLast = _current == _steps.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text('${e.name}${e.isWarmup ? '' : ' - set ${step.setNumber}/${e.sets}'}'),
        ),
        actions: [
          TextButton(
            onPressed: _finishing
                ? null
                : () async {
                    if (await _confirmFinishEarly()) {
                      await _finish(wrapUp: true);
                    }
                  },
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
                      else if (e.isTravel)
                        const Chip(
                          avatar: Icon(Icons.luggage_outlined, size: 18),
                          label: Text('Travel · no equipment'),
                        ),
                      if (!e.isWarmup && _superset && partner != null)
                        Chip(
                          avatar: const Icon(Icons.swap_vert, size: 18),
                          label: Text('Superset — next: $partner'),
                        ),
                      const SizedBox(height: 12),
                      Text(
                        'Target: ${e.targetLabel}'
                        '${currentLoadDisplay == null ? '' : ' @ $currentLoadDisplay'}',
                        style: Theme.of(context).textTheme.bodyLarge,
                        textAlign: TextAlign.center,
                      ),
                      if (e.instruction != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          e.instruction!,
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (!e.isWarmup &&
                          e.progressionFraction != null) ...[
                        const SizedBox(height: 12),
                        ProgressionPanel(exercise: e),
                      ],
                      const SizedBox(height: 20),
                      if (e.loadTotal != null || e.loadSteps != null)
                        _weightStepper(
                          currentLoadDisplay,
                        )
                      else if (!e.isWarmup)
                        const Text('Bodyweight', style: TextStyle(fontWeight: FontWeight.bold)),
                      _valueStepper(),
                      if (e.metric == ExerciseMetric.seconds) _holdCountdown(),
                      const SizedBox(height: 16),
                      if (!e.isWarmup)
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
                  onPressed:
                      _finishing || _loggedValue <= 0 ? null : _logSet,
                  child: Text(_logButtonLabel(e, isLast)),
                ),
              ),
              if (!isLast) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _finishing
                        ? null
                        : () async {
                            if (await _confirmFinishEarly()) {
                              await _finish(wrapUp: true);
                            }
                          },
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

  /// Resolves the in-hand setup every build so a real achievable increment is
  /// immediately visible. The logged value itself remains [loadTotal]'s
  /// historical total — only the label changes.
  String? _loadDisplay(
    PlannedExercise exercise,
    double total,
    EquipmentConfig? equipment, {
    int? setNumber,
  }) {
    if (exercise.loadTotal == null && exercise.loadSteps == null) return null;
    final count = exercise.dumbbellCount;
    if (count == 1 && equipment != null) {
      return const EquipmentEngine().describeLoad(
        const EquipmentEngine().resolveSingleDb(total, equipment),
        equipment,
        setNumber: setNumber,
      );
    }
    if (count == 2 && equipment != null) {
      // This plan's achievable totals were generated with uneven-pair mode
      // allowed. Keep that physical resolution stable for the active plan if
      // the user later turns the global toggle off; otherwise 49 would be
      // shown as a fallback 48 while 49 is still what gets logged.
      final displayEquipment = exercise.allowsUnevenPair == true
          ? equipment.copyWith(unevenPairModeEnabled: true)
          : equipment;
      return const EquipmentEngine().describeLoad(
        const EquipmentEngine().resolveTwoDb(
          total,
          displayEquipment,
          allowUneven: exercise.allowsUnevenPair ?? false,
        ),
        displayEquipment,
        setNumber: setNumber,
      );
    }
    // Metadata absent means this was saved by an older build. Do not infer
    // dumbbell count from its total: that would silently reinterpret history.
    return '${_formatLoad(total)} lb';
  }

  String _formatLoad(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();

  Widget _weightStepper(String? currentLoadDisplay) {
    final w = _weightByExercise[_steps[_current].exIdx] ?? 0;
    final label = switch (_exercise.dumbbellCount) {
      1 => 'Dumbbell load',
      2 => 'Dumbbells',
      _ => 'Weight',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        Row(
          children: [
            IconButton.filledTonal(
              onPressed: () => _stepWeight(-1),
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: Text(
                currentLoadDisplay ?? '${_formatLoad(w)} lb',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton.filledTonal(
              onPressed: () => _stepWeight(1),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    );
  }

  Widget _valueStepper() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(width: 90, child: Text(_exercise.metric.inputLabel)),
        IconButton.filledTonal(
            onPressed: () => _stepValue(-1),
            icon: const Icon(Icons.remove)),
        SizedBox(
          width: 96,
          child: Text('$_value', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
        ),
        IconButton.filledTonal(
            onPressed: () => _stepValue(1),
            icon: const Icon(Icons.add)),
      ],
    );
  }

  Widget _holdCountdown() {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('$_holdSecondsLeft s', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              onPressed: _value <= 0 ? null : _toggleHoldTimer,
              icon: Icon(_holdRunning ? Icons.pause : Icons.play_arrow),
              label: Text(_holdRunning ? 'Pause' : 'Start hold'),
            ),
            IconButton(
              tooltip: 'Reset hold timer',
              onPressed: _resetHoldTimer,
              icon: const Icon(Icons.replay),
            ),
          ],
        ),
      ),
    );
  }

  String _logButtonLabel(PlannedExercise exercise, bool isLast) {
    final action = exercise.isWarmup
        ? 'Log warm-up'
        : exercise.metric == ExerciseMetric.seconds
            ? 'Log hold'
            : 'Log set';
    return isLast ? '$action & finish' : action;
  }

  String _rirLabel(Rir r) => switch (r) {
        Rir.rir0 => 'RIR 0',
        Rir.rir1 => 'RIR 1',
        Rir.rir2 => 'RIR 2',
        Rir.rir3plus => 'RIR 3+',
        Rir.rir4plus => 'RIR 4+',
      };
}
