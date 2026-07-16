import 'floor_category.dart';

/// §2.1 session type identifiers (the queue).
enum SessionTypeId { s1, s2, s3, s4, s5, s6, s7 }

/// Time tiers a session can run at (§2.5, §7 Step 2/7).
enum SessionTier { compressed, full, extended }

class SessionTypeDef {
  final SessionTypeId id;
  final String name;
  final int fullDurationMin;

  /// Null means "not compressible" (S3): it either runs full or is
  /// substituted entirely (S3 -> S7) rather than shrunk.
  final int? minDurationMin;
  final bool legHeavy;
  final Set<FloorCategory> countsAs;

  /// Only cycle members participate in queue pointer/served mechanics (§2.1).
  final bool cycleMember;

  const SessionTypeDef({
    required this.id,
    required this.name,
    required this.fullDurationMin,
    required this.minDurationMin,
    required this.legHeavy,
    required this.countsAs,
    required this.cycleMember,
  });

  bool get isCompressible => minDurationMin != null;
}

/// The five cycle types in repeat order, per §2.1.
const List<SessionTypeId> cycleOrder = [
  SessionTypeId.s1,
  SessionTypeId.s2,
  SessionTypeId.s3,
  SessionTypeId.s4,
  SessionTypeId.s5,
];

final Map<SessionTypeId, SessionTypeDef> sessionTypes = {
  SessionTypeId.s1: const SessionTypeDef(
    id: SessionTypeId.s1,
    name: 'Lower Strength',
    fullDurationMin: 35,
    minDurationMin: 20,
    legHeavy: true,
    countsAs: {FloorCategory.strength},
    cycleMember: true,
  ),
  SessionTypeId.s2: const SessionTypeDef(
    id: SessionTypeId.s2,
    name: 'Upper Strength',
    fullDurationMin: 60,
    minDurationMin: 20,
    legHeavy: false,
    // Intensity credit only applies if REHIT finisher completed - handled
    // dynamically in session logging, not as a static flag here.
    countsAs: {FloorCategory.strength},
    cycleMember: true,
  ),
  SessionTypeId.s3: const SessionTypeDef(
    id: SessionTypeId.s3,
    name: 'CAROL 4×4 Norwegian Zone 5 Intervals',
    fullDurationMin: 30,
    minDurationMin: null,
    legHeavy: true,
    countsAs: {FloorCategory.intensity},
    cycleMember: true,
  ),
  SessionTypeId.s4: const SessionTypeDef(
    id: SessionTypeId.s4,
    name: 'Full Body + ATG Mobility Block',
    fullDurationMin: 60,
    minDurationMin: 20,
    legHeavy: true,
    countsAs: {FloorCategory.strength},
    cycleMember: true,
  ),
  SessionTypeId.s5: const SessionTypeDef(
    id: SessionTypeId.s5,
    name: 'Flex / Pump (ATG 1)',
    fullDurationMin: 35,
    minDurationMin: 20,
    legHeavy: false,
    countsAs: {FloorCategory.strength},
    cycleMember: true,
  ),
  SessionTypeId.s6: const SessionTypeDef(
    id: SessionTypeId.s6,
    name: 'Zone 2',
    fullDurationMin: 60,
    // Thirty minutes is the base-target credit threshold. Decision may emit
    // an explicit 20-minute recovery prescription inside the immutable hard
    // time window, but that shorter dose earns no base-target credit.
    minDurationMin: 30,
    legHeavy: false,
    countsAs: {FloorCategory.aerobic},
    cycleMember: false,
  ),
  SessionTypeId.s7: const SessionTypeDef(
    id: SessionTypeId.s7,
    name: 'CAROL REHIT Intense',
    // CAROL currently reports 5:00–8:40 for this fixed preset. Reserve the
    // conservative rounded 9-minute upper bound in strength/time budgeting,
    // while 5 minutes is the minimum bike-guided completion duration.
    fullDurationMin: 9,
    minDurationMin: 5,
    legHeavy: false,
    countsAs: {FloorCategory.intensity},
    cycleMember: false,
  ),
};
