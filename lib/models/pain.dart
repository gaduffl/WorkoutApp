import 'movement_pattern.dart';

enum BodyRegion { lowerBack, kneeLeft, kneeRight, shoulderLeft, shoulderRight, elbow, wrist, hip }

enum PainSeverity { mild, sharp }

/// Extra symptom tags that trigger the hard-coded escalation rule (§7.2).
enum PainTag {
  radiating,
  numbness,
  tingling,
  weakness,
  saddleNumbness,
  bladderBowelChange,
}

extension BodyRegionX on BodyRegion {
  /// §7.1 region -> affected pattern(s) table.
  List<MovementPattern> get affectedPatterns {
    switch (this) {
      case BodyRegion.lowerBack:
        return [MovementPattern.hinge, MovementPattern.squat];
      case BodyRegion.kneeLeft:
      case BodyRegion.kneeRight:
        return [MovementPattern.squat];
      case BodyRegion.shoulderLeft:
      case BodyRegion.shoulderRight:
        return [MovementPattern.pushHorizontal, MovementPattern.pushVertical, MovementPattern.pullVertical, MovementPattern.pullHorizontal];
      case BodyRegion.elbow:
      case BodyRegion.wrist:
        return [MovementPattern.pullVertical, MovementPattern.pullHorizontal, MovementPattern.coreGrip, MovementPattern.pushVertical, MovementPattern.pushHorizontal];
      case BodyRegion.hip:
        return [MovementPattern.squat, MovementPattern.hinge];
    }
  }
}

class PainFlag {
  final BodyRegion region;
  final PainSeverity severity;
  final DateTime flaggedDate;
  final Set<PainTag> tags;

  const PainFlag({
    required this.region,
    required this.severity,
    required this.flaggedDate,
    this.tags = const {},
  });

  PainFlag copyWith({PainSeverity? severity, DateTime? flaggedDate, Set<PainTag>? tags}) {
    return PainFlag(
      region: region,
      severity: severity ?? this.severity,
      flaggedDate: flaggedDate ?? this.flaggedDate,
      tags: tags ?? this.tags,
    );
  }
}
