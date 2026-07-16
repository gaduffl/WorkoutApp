import 'package:flutter/material.dart';

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
    'On CAROL, select “REHIT Intense (2×20-second sprints)” and complete the bike-guided preset. CAROL controls its 5:00–8:40 timing.';

/// One in-budget step of the protocol card's actionable timeline.
class CardioTimelineSegment {
  final String label;
  final int durationSeconds;

  const CardioTimelineSegment({
    required this.label,
    required this.durationSeconds,
  });

  String get summaryLine => '${_clock(durationSeconds)} · $label';
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
          label:
              'Continuous: ease into target effort within the prescribed duration',
          durationSeconds: prescription.plannedDurationSeconds,
        ),
      ];
  }
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
}) =>
    showDialog<CardioCompletion>(
      context: context,
      builder: (_) => _CardioCompletionDialog(
        prescription: prescription,
        title: title,
      ),
    );

class _CardioCompletionDialog extends StatefulWidget {
  final CardioPrescription prescription;
  final String title;

  const _CardioCompletionDialog({
    required this.prescription,
    required this.title,
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
  String? _error;

  bool get _isContinuous =>
      widget.prescription.protocol.type == CardioProtocolType.zone2Base;

  bool get _isCarolPreset =>
      widget.prescription.protocol.type != CardioProtocolType.zone2Base;

  @override
  void initState() {
    super.initState();
    _intervals = TextEditingController(
      text: widget.prescription.plannedWorkIntervals.toString(),
    );
    _duration = TextEditingController(
      text: _isCarolPreset
          ? _clock(widget.prescription.plannedDurationSeconds)
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
    super.dispose();
  }

  void _save() {
    try {
      final intervals = _isContinuous ? 1 : int.parse(_intervals.text.trim());
      final averageHr = _optionalDouble(_averageHr, 'Average HR');
      final peakHr = _optionalDouble(_peakHr, 'Peak HR');
      final rpe = _optionalDouble(_rpe, 'RPE');
      final completion = _isCarolPreset
          ? const CardioEngine().completionFromElapsedSeconds(
              prescription: widget.prescription,
              completedWorkIntervals: intervals,
              completedDurationSeconds: _carolDurationSeconds(),
              averageHeartRateBpm: averageHr,
              peakHeartRateBpm: peakHr,
              rpe: rpe,
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
    final parts = _duration.text.trim().split(':');
    if (parts.length != 2) {
      throw const FormatException('CAROL duration as M:SS');
    }
    final minutes = int.tryParse(parts[0]);
    final seconds = int.tryParse(parts[1]);
    if (minutes == null ||
        seconds == null ||
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
              keyboardType: _isCarolPreset
                  ? TextInputType.datetime
                  : TextInputType.number,
              decoration: InputDecoration(
                labelText: _isCarolPreset
                    ? 'Duration shown by CAROL (M:SS)'
                    : 'Duration (min)',
              ),
            ),
            spacing,
            TextField(
              controller: _averageHr,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Average HR (optional)'),
            ),
            spacing,
            TextField(
              controller: _peakHr,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Peak HR (optional)'),
            ),
            spacing,
            TextField(
              controller: _rpe,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'RPE 0–10 (optional)'),
            ),
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
          child: const Text('Save attempt'),
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

String _plainDuration(int seconds) {
  if (seconds < 60) return '$seconds sec';
  if (seconds % 60 == 0) return '${seconds ~/ 60} min';
  return '${seconds ~/ 60} min ${seconds % 60} sec';
}
