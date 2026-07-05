import 'pain.dart';

/// §3 morning check-in / §2.4 CheckIn entity.
/// `timeMinutes` uses 0 for rest/no slot, otherwise 20/35/60.
class CheckIn {
  final DateTime date;
  final int timeMinutes;
  final int subjective; // 1-5
  final List<PainFlag> pain;
  final String? notes;
  final DateTime timestamp;

  const CheckIn({
    required this.date,
    required this.timeMinutes,
    required this.subjective,
    this.pain = const [],
    this.notes,
    required this.timestamp,
  });
}
