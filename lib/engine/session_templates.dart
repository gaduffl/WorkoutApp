import '../models/movement_pattern.dart';
import '../models/session_type.dart';

/// §2.5 prescription defaults: work sets per exercise before readiness
/// modulation, by tier and exercise class.
const Map<SessionTier, int> compoundSetsByTier = {
  SessionTier.extended: 3,
  SessionTier.full: 3,
  SessionTier.compressed: 2,
};

const Map<SessionTier, int> accessorySetsByTier = {
  SessionTier.extended: 3,
  SessionTier.full: 2,
  SessionTier.compressed: 0,
};

/// Which movement patterns a session template trains. Tier only changes
/// set counts (§2.5) and, at compressed tier, trims to the first superset
/// pair only - the pattern list itself is defined once here.
class SessionTemplateDef {
  final SessionTypeId id;
  final List<MovementPattern> compoundPatterns;
  final List<MovementPattern> accessoryPatterns;
  final bool hasKneeHealthBlock;
  final bool hasOptionalRehitFinisher;
  final bool isCardioOnly;

  const SessionTemplateDef({
    required this.id,
    this.compoundPatterns = const [],
    this.accessoryPatterns = const [],
    this.hasKneeHealthBlock = false,
    this.hasOptionalRehitFinisher = false,
    this.isCardioOnly = false,
  });

  /// (pattern, isCompound) slots surviving at [tier].
  List<(MovementPattern, bool)> slotsForTier(SessionTier tier) {
    if (isCardioOnly) return const [];
    if (tier == SessionTier.compressed) {
      final source = compoundPatterns.isNotEmpty ? compoundPatterns : accessoryPatterns;
      return source.take(2).map((p) => (p, compoundPatterns.isNotEmpty)).toList();
    }
    return [
      for (final p in compoundPatterns) (p, true),
      for (final p in accessoryPatterns) (p, false),
    ];
  }

  int setsFor(bool isCompound, SessionTier tier) {
    return isCompound ? compoundSetsByTier[tier]! : accessorySetsByTier[tier]!;
  }
}

final Map<SessionTypeId, SessionTemplateDef> sessionTemplates = {
  SessionTypeId.s1: const SessionTemplateDef(
    id: SessionTypeId.s1,
    compoundPatterns: [MovementPattern.squat, MovementPattern.hinge],
  ),
  SessionTypeId.s2: const SessionTemplateDef(
    id: SessionTypeId.s2,
    compoundPatterns: [
      MovementPattern.pushHorizontal,
      MovementPattern.pullHorizontal,
      MovementPattern.pushVertical,
      MovementPattern.pullVertical,
    ],
    accessoryPatterns: [MovementPattern.coreGrip],
    hasOptionalRehitFinisher: true,
  ),
  SessionTypeId.s3: const SessionTemplateDef(id: SessionTypeId.s3, isCardioOnly: true),
  SessionTypeId.s4: const SessionTemplateDef(
    id: SessionTypeId.s4,
    compoundPatterns: [
      MovementPattern.squat,
      MovementPattern.hinge,
      MovementPattern.pushHorizontal,
      MovementPattern.pullHorizontal,
    ],
    accessoryPatterns: [MovementPattern.coreGrip],
    hasKneeHealthBlock: true,
  ),
  SessionTypeId.s5: const SessionTemplateDef(
    id: SessionTypeId.s5,
    accessoryPatterns: [MovementPattern.pushVertical, MovementPattern.pullHorizontal, MovementPattern.coreGrip],
  ),
  SessionTypeId.s6: const SessionTemplateDef(id: SessionTypeId.s6, isCardioOnly: true),
  SessionTypeId.s7: const SessionTemplateDef(id: SessionTypeId.s7, isCardioOnly: true),
};

SessionTier tierForTime(int minutes) {
  if (minutes >= 60) return SessionTier.extended;
  if (minutes >= 35) return SessionTier.full;
  return SessionTier.compressed;
}
