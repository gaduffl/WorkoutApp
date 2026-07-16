import '../models/ladders.dart';
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

  /// Named accessory exercises (S5 arms/shoulders) that don't live on a
  /// pattern ladder — each carries its own state track via the registry.
  final List<SubstituteExercise> namedAccessories;
  final bool hasKneeHealthBlock;
  final bool hasOptionalRehitFinisher;
  final bool isCardioOnly;

  const SessionTemplateDef({
    required this.id,
    this.compoundPatterns = const [],
    this.accessoryPatterns = const [],
    this.namedAccessories = const [],
    this.hasKneeHealthBlock = false,
    this.hasOptionalRehitFinisher = false,
    this.isCardioOnly = false,
  });

  /// (pattern, usesCompoundSetCount, namedExercise?) slots surviving at
  /// [tier]. The boolean controls set-count bookkeeping only. A compressed
  /// named accessory may use the compound count without becoming a genuine
  /// compound for warm-up or duration-budget purposes.
  ///
  /// [dropAccessories] implements §5 Step 7's "60 → 35" compression for
  /// natively-60-minute sessions (S2/S4) running in a 35-minute slot:
  /// keep all primary superset pairs, drop the accessory block.
  List<(MovementPattern, bool, SubstituteExercise?)> slotsForTier(SessionTier tier, {bool dropAccessories = false}) {
    if (isCardioOnly) return const [];
    final compounds = [for (final p in compoundPatterns) (p, true, null as SubstituteExercise?)];
    final named = [for (final n in namedAccessories) (n.pattern, false, n as SubstituteExercise?)];
    final accessories = [for (final p in accessoryPatterns) (p, false, null as SubstituteExercise?)];
    if (tier == SessionTier.compressed) {
      // §2.5: compressed tier is "first superset pair only, 2 hard sets
      // each" - that applies to whichever exercises survive, even for a
      // template with no compound-bucketed patterns at all (S5). Marking
      // these `false` here would fall through to the *accessory* set count
      // (0 at compressed tier), leaving the session with zero work sets.
      final source = compounds.isNotEmpty ? compounds : [...named, ...accessories];
      return source.take(2).map((s) => (s.$1, true, s.$3)).toList();
    }
    if (dropAccessories && compounds.isNotEmpty) return compounds;
    return [...compounds, ...named, ...accessories];
  }

  int setsFor(bool usesCompoundSetCount, SessionTier tier) {
    return usesCompoundSetCount
        ? compoundSetsByTier[tier]!
        : accessorySetsByTier[tier]!;
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
    // §2.1: "Flex / Pump (arms, shoulders, core)" - direct arm work plus
    // the core/grip ladder, not the push/pull proxies used before.
    namedAccessories: s5NamedAccessories,
    accessoryPatterns: [MovementPattern.coreGrip],
  ),
  SessionTypeId.s6: const SessionTemplateDef(id: SessionTypeId.s6, isCardioOnly: true),
  SessionTypeId.s7: const SessionTemplateDef(id: SessionTypeId.s7, isCardioOnly: true),
};

SessionTier tierForTime(int minutes) {
  if (minutes >= 60) return SessionTier.extended;
  if (minutes >= 35) return SessionTier.full;
  return SessionTier.compressed;
}
