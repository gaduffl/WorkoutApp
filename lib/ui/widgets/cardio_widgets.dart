import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/cardio_engine.dart';
import '../../models/cardio_protocol.dart';

String cardioTalkTestCue(CardioProtocolType type) => switch (type) {
      CardioProtocolType.norwegian4x4 =>
        'Talk test: only a few words during work intervals',
      CardioProtocolType.zone2Base =>
        'Talk test: full sentences with controlled breathing',
      CardioProtocolType.rehit =>
        'Talk test: talking is not possible during the sprints',
    };

const carolFourByFourInstruction =
    'On CAROL, select “4×4 Norwegian Zone 5 Intervals” and complete the bike-guided 30-minute preset.';
const carolRehitInstruction =
    'On CAROL, select “REHIT Intense (2×20-second sprints)” and complete the fixed 08:40 bike-guided preset.';

/// Lets a number-only keyboard enter CAROL's `MM:SS` value without exposing
/// a colon key. The colon is inserted after the first two digits, while an
/// already formatted value remains normally editable and pasteable.
class CarolDurationInputFormatter extends TextInputFormatter {
  const CarolDurationInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue;
    if (!RegExp(r'^[0-9:]*$').hasMatch(text)) return oldValue;

    if (text.contains(':')) {
      final parts = text.split(':');
      if (parts.length != 2 ||
          parts.first.length > 2 ||
          parts.last.length > 2 ||
          text.length > 5) {
        return oldValue;
      }
      return newValue;
    }

    if (text.length > 4) return oldValue;
    if (text.length <= 2) return newValue;

    final formatted = '${text.substring(0, 2)}:${text.substring(2)}';
    final rawOffset =
        newValue.selection.baseOffset.clamp(0, text.length).toInt();
    final formattedOffset = rawOffset > 2 ? rawOffset + 1 : rawOffset;
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formattedOffset),
    );
  }
}

/// One in-budget step of the protocol card's actionable timeline.
class CardioTimelineSegment {
  final String label;
  final int durationSeconds;

  const CardioTimelineSegment({
    required this.label,
    required this.durationSeconds,
  });

  String get summaryLine => '0:00–${_clock(durationSeconds)} · $label';
}

/// Zone 2 is app-timed continuous work. CAROL owns every internal segment of
/// its fixed interval presets, so those protocols intentionally expose no
/// app-authored timeline.
List<CardioTimelineSegment> cardioProtocolTimeline(
  CardioPrescription prescription,
) {
  switch (prescription.protocol.type) {
    case CardioProtocolType.norwegian4x4:
    case CardioProtocolType.rehit:
      return const [];

    case CardioProtocolType.zone2Base:
      return [
        CardioTimelineSegment(
          label: _zone2ContinuousInstruction(prescription),
          durationSeconds: prescription.plannedDurationSeconds,
        ),
      ];
  }
}

String _zone2ContinuousInstruction(CardioPrescription prescription) {
  final hrMin = prescription.targetHeartRateMinBpm;
  final hrMax = prescription.targetHeartRateMaxBpm;
  final rpeMin = prescription.targetRpeMin;
  final rpeMax = prescription.targetRpeMax;
  final rpeRange = rpeMin != null && rpeMax != null
      ? ' (RPE ${_number(rpeMin)}–${_number(rpeMax)})'
      : '';

  final targetCue = switch ((hrMin, hrMax, rpeMin, rpeMax)) {
    (final min?, final max?, _, _) =>
      'Start near ${min.round()} bpm; adjust resistance/cadence to stay at ${min.round()}–${max.round()} bpm$rpeRange.',
    (_, _, final min?, final max?) =>
      'Start near RPE ${_number(min)}; adjust resistance/cadence to stay at RPE ${_number(min)}–${_number(max)}.',
    (final min?, _, _, _) =>
      'Start near ${min.round()} bpm; adjust resistance/cadence to keep the effort comfortably sustainable.',
    (_, final max?, _, _) =>
      'Stay at or below ${max.round()} bpm; adjust resistance/cadence to keep the effort comfortably sustainable.',
    _ =>
      'Adjust resistance/cadence as needed to keep the effort comfortably sustainable.',
  };
  return 'Ride continuously in Zone 2.\n$targetCue';
}

List<String> cardioPrescriptionSummaryLines(
  CardioPrescription prescription,
) {
  final protocol = prescription.protocol.type;
  if (protocol == CardioProtocolType.norwegian4x4 ||
      protocol == CardioProtocolType.rehit) {
    final targets = _cardioTargets(prescription);
    return [
      protocol == CardioProtocolType.norwegian4x4
          ? carolFourByFourInstruction
          : carolRehitInstruction,
      if (targets.isNotEmpty)
        'Coaching target: ${targets.join(' · ')}',
      cardioTalkTestCue(protocol),
    ];
  }

  final dose = switch (protocol) {
    CardioProtocolType.zone2Base =>
      'Continuous ${_plainDuration(prescription.plannedWorkSeconds)}',
    CardioProtocolType.norwegian4x4 =>
      throw StateError('CAROL preset handled above'),
    CardioProtocolType.rehit =>
      throw StateError('CAROL preset handled above'),
  };

  final targets = _cardioTargets(prescription);
  final lines = <String>[
    dose,
    if (targets.isNotEmpty) 'Target: ${targets.join(' · ')}',
    cardioTalkTestCue(protocol),
  ];
  if (prescription.plannedWorkSeconds < 1800) {
    lines.add('Recovery dose: below the 30-min base-credit threshold');
  }
  lines.add('Timeline (${_clock(prescription.plannedDurationSeconds)} total)');
  lines.addAll(
    cardioProtocolTimeline(prescription).map((segment) => segment.summaryLine),
  );
  return lines;
}

List<String> _cardioTargets(CardioPrescription prescription) {
  final targets = <String>[];
  if (prescription.targetHeartRateMinBpm != null &&
      prescription.targetHeartRateMaxBpm != null) {
    targets.add(
      '${prescription.targetHeartRateMinBpm!.round()}–'
      '${prescription.targetHeartRateMaxBpm!.round()} bpm',
    );
  }
  if (prescription.targetRpeMin != null && prescription.targetRpeMax != null) {
    targets.add(
      'RPE ${_number(prescription.targetRpeMin!)}–'
      '${_number(prescription.targetRpeMax!)}',
    );
  }
  return targets;
}

class CardioPrescriptionCard extends StatelessWidget {
  final CardioPrescription prescription;

  const CardioPrescriptionCard({
    super.key,
    required this.prescription,
  });

  @override
  Widget build(BuildContext context) {
    final lines = cardioPrescriptionSummaryLines(prescription);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.directions_bike),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    prescription.protocol.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  ...lines.map(
                    (line) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(line),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<CardioCompletion?> showCardioCompletionDialog(
  BuildContext context, {
  required CardioPrescription prescription,
  String title = 'Log cardio attempt',
  bool unplannedRide = false,
}) =>
    showDialog<CardioCompletion>(
      context: context,
      builder: (_) => _CardioCompletionDialog(
        prescription: prescription,
        title: title,
        unplannedRide: unplannedRide,
      ),
    );

class _CardioCompletionDialog extends StatefulWidget {
  final CardioPrescription prescription;
  final String title;
  final bool unplannedRide;

  const _CardioCompletionDialog({
    required this.prescription,
    required this.title,
    this.unplannedRide = false,
  });

  @override
  State<_CardioCompletionDialog> createState() =>
      _CardioCompletionDialogState();
}

class _CardioCompletionDialogState extends State<_CardioCompletionDialog> {
  late final TextEditingController _intervals;
  late final TextEditingController _duration;
  final _averageHr = TextEditingController();
  final _peakHr = TextEditingController();
  final _rpe = TextEditingController();
  final _fitnessScore = TextEditingController();
  final _peakPower = TextEditingController();
  String? _error;

  bool get _isContinuous =>
      widget.prescription.protocol.type == CardioProtocolType.zone2Base;

  bool get _isCarolPreset =>
      widget.prescription.protocol.type != CardioProtocolType.zone2Base;

  bool get _isRehit =>
      widget.prescription.protocol.type == CardioProtocolType.rehit;

  @override
  void initState() {
    super.initState();
    _intervals = TextEditingController(
      text: widget.prescription.plannedWorkIntervals.toString(),
    );
    _duration = TextEditingController(
      text: widget.unplannedRide
          ? ''
          : _isCarolPreset
              ? _carolClock(widget.prescription.plannedDurationSeconds)
              : ((widget.prescription.plannedDurationSeconds + 59) ~/ 60)
                  .toString(),
    );
  }

  @override
  void dispose() {
    _intervals.dispose();
    _duration.dispose();
    _averageHr.dispose();
    _peakHr.dispose();
    _rpe.dispose();
    _fitnessScore.dispose();
    _peakPower.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final intervals = _isContinuous ? 1 : int.parse(_intervals.text.trim());
      final averageHr =
          _isContinuous ? _optionalDouble(_averageHr, 'Average HR') : null;
      final peakHr =
          _isContinuous ? _optionalDouble(_peakHr, 'Peak HR') : null;
      final rpe = _isContinuous ? _optionalDouble(_rpe, 'RPE') : null;
      final fitnessScore = _isRehit
          ? _optionalDouble(_fitnessScore, 'Fitness Score')
          : null;
      final peakPower = _isRehit
          ? _optionalDouble(_peakPower, 'Peak Power')
          : null;
      final completion = _isCarolPreset
          ? const CardioEngine().completionFromElapsedSeconds(
              prescription: widget.prescription,
              completedWorkIntervals: intervals,
              completedDurationSeconds: _carolDurationSeconds(),
              averageHeartRateBpm: averageHr,
              peakHeartRateBpm: peakHr,
              rpe: rpe,
              fitnessScore: fitnessScore,
              peakPowerWatts: peakPower,
            )
          : const CardioEngine().completionFromEntry(
              prescription: widget.prescription,
              completedWorkIntervals: intervals,
              completedDurationMinutes: int.parse(_duration.text.trim()),
              averageHeartRateBpm: averageHr,
              peakHeartRateBpm: peakHr,
              rpe: rpe,
            );
      Navigator.of(context).pop(completion);
    } catch (error) {
      setState(() {
        _error = error
            .toString()
            .replaceFirst('Invalid argument(s): ', '')
            .replaceFirst('FormatException: ', 'Enter valid numbers: ');
      });
    }
  }

  double? _optionalDouble(TextEditingController controller, String label) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null) throw FormatException(label);
    return value;
  }

  int _carolDurationSeconds() {
    final raw = _duration.text.trim();
    final normalized = raw.contains(':')
        ? raw
        : raw.length == 4 && RegExp(r'^\d{4}$').hasMatch(raw)
            ? '${raw.substring(0, 2)}:${raw.substring(2)}'
            : raw;
    final parts = normalized.split(':');
    if (parts.length != 2) {
      throw const FormatException('CAROL duration as M:SS');
    }
    final minutes = int.tryParse(parts[0]);
    final seconds = int.tryParse(parts[1]);
    if (minutes == null ||
        seconds == null ||
        parts[1].length != 2 ||
        minutes < 0 ||
        seconds < 0 ||
        seconds > 59 ||
        minutes * 60 + seconds <= 0) {
      throw const FormatException('CAROL duration as M:SS (seconds 00–59)');
    }
    return minutes * 60 + seconds;
  }

  @override
  Widget build(BuildContext context) {
    const spacing = SizedBox(height: 10);
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.prescription.protocol.name,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            spacing,
            if (widget.unplannedRide) ...[
              const Text(
                'Record a Zone 2 ride you already completed today. '
                'It counts toward your training history and aerobic targets, '
                'but does not complete or replace your MorningCoach plan.',
              ),
              spacing,
            ],
            if (!_isContinuous) ...[
              TextField(
                controller: _intervals,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Completed intervals',
                  helperText:
                      'Planned: ${widget.prescription.plannedWorkIntervals}',
                ),
              ),
              spacing,
            ],
            TextField(
              controller: _duration,
              keyboardType: TextInputType.number,
              inputFormatters: _isCarolPreset
                  ? const [CarolDurationInputFormatter()]
                  : null,
              decoration: InputDecoration(
                labelText: _isCarolPreset
                    ? 'Duration shown by CAROL (M:SS)'
                    : 'Duration (min)',
                helperText: _isContinuous
                    ? widget.unplannedRide
                        ? 'Actual ride time, 1–1440 minutes'
                        : 'Actual ride time; may exceed the plan'
                    : null,
              ),
            ),
            spacing,
            if (_isContinuous) ...[
              TextField(
                controller: _averageHr,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Average HR (optional)'),
              ),
              spacing,
              TextField(
                controller: _peakHr,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Peak HR (optional)'),
              ),
              spacing,
              TextField(
                controller: _rpe,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'RPE 0–10 (optional)'),
              ),
            ] else if (_isRehit) ...[
              TextField(
                controller: _fitnessScore,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Fitness Score (optional)',
                ),
              ),
              spacing,
              TextField(
                controller: _peakPower,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Peak Power (W, optional)',
                ),
              ),
            ],
            if (_error != null) ...[
              spacing,
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(widget.unplannedRide ? 'Save ride' : 'Save attempt'),
        ),
      ],
    );
  }
}

String _number(double value) =>
    value == value.roundToDouble() ? value.round().toString() : value.toStringAsFixed(1);

String _clock(int seconds) {
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return '$minutes:${remainder.toString().padLeft(2, '0')}';
}

String _carolClock(int seconds) {
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remainder.toString().padLeft(2, '0')}';
}

String _plainDuration(int seconds) {
  if (seconds < 60) return '$seconds sec';
  if (seconds % 60 == 0) return '${seconds ~/ 60} min';
  return '${seconds ~/ 60} min ${seconds % 60} sec';
}
