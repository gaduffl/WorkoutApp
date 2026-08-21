import 'exercise_metric.dart';
import 'movement_pattern.dart';

/// §2.3: ladder steps, easiest -> hardest. `dumbbells` is 0 for
/// bodyweight/assisted steps, 1 for single-DB, 2 for a matched pair.
/// `backpackLoaded` marks weighted pull-up/dip style steps (§2.6 rule 5):
/// achievable set = single-DB union, backpack contents are free entry.
class LadderStep {
  final String name;
  final String? visualId;
  final int dumbbells;
  final bool backpackLoaded;

  /// Per-step measurement and optional target. This deliberately lives on
  /// the step rather than [MovementPattern], because core/grip mixes timed
  /// holds with rep-based wrist curls.
  final ExerciseMetric metric;
  final (int, int)? targetRange;

  /// True for single-leg/single-arm steps - excludes uneven-pair mode
  /// even when 2 dumbbells are held (§2.6 rule 3).
  final bool unilateral;

  const LadderStep({
    required this.name,
    this.visualId,
    this.dumbbells = 0,
    this.backpackLoaded = false,
    this.unilateral = false,
    this.metric = ExerciseMetric.reps,
    this.targetRange,
  });
}

class MovementLadder {
  final MovementPattern pattern;
  final List<LadderStep> steps;

  const MovementLadder({required this.pattern, required this.steps});
}

final Map<MovementPattern, MovementLadder> ladders = {
  MovementPattern.squat: const MovementLadder(
    pattern: MovementPattern.squat,
    steps: [
      LadderStep(
        name: 'Goblet squat',
        dumbbells: 1,
        visualId: 'dumbbellGobletSquat',
      ),
      LadderStep(name: 'DB squat', dumbbells: 2),
      LadderStep(
        name: 'Rear-foot-elevated split squat',
        dumbbells: 2,
        unilateral: true,
      ),
      LadderStep(name: 'ATG split squat', dumbbells: 2, unilateral: true),
      LadderStep(
        name: 'ATG split squat, front foot elevated',
        dumbbells: 2,
        unilateral: true,
      ),
      LadderStep(
        name: 'ATG split squat, front foot elevated +tempo/pause',
        dumbbells: 2,
        unilateral: true,
      ),
    ],
  ),
  MovementPattern.hinge: const MovementLadder(
    pattern: MovementPattern.hinge,
    steps: [
      LadderStep(name: 'Elevated-start DB deadlift (on blocks)', dumbbells: 2),
      LadderStep(name: 'DB deadlift, floor', dumbbells: 2),
      LadderStep(name: 'DB RDL', dumbbells: 2),
      LadderStep(name: 'Deficit RDL (standing on blocks)', dumbbells: 2),
      LadderStep(name: 'Single-leg RDL', dumbbells: 2, unilateral: true),
      LadderStep(name: 'Single-leg RDL +tempo', dumbbells: 2, unilateral: true),
    ],
  ),
  MovementPattern.pushHorizontal: const MovementLadder(
    pattern: MovementPattern.pushHorizontal,
    steps: [
      LadderStep(name: 'Push-up', visualId: 'pushUp'),
      LadderStep(name: 'DB bench on bolster', dumbbells: 2),
      LadderStep(name: 'One-arm DB bench', dumbbells: 1, unilateral: true),
      LadderStep(name: 'One-arm DB bench +3s eccentric', dumbbells: 1, unilateral: true),
      LadderStep(name: 'Deficit push-up (blocks), weighted', dumbbells: 1),
    ],
  ),
  MovementPattern.pushVertical: const MovementLadder(
    pattern: MovementPattern.pushVertical,
    steps: [
      LadderStep(
        name: 'Seated DB press',
        dumbbells: 2,
        visualId: 'seatedDumbbellShoulderPress',
      ),
      LadderStep(name: 'Standing DB press', dumbbells: 2),
      LadderStep(name: 'Single-arm standing press', dumbbells: 1, unilateral: true),
      LadderStep(name: 'Single-arm standing press +pause/tempo', dumbbells: 1, unilateral: true),
    ],
  ),
  MovementPattern.pullVertical: const MovementLadder(
    pattern: MovementPattern.pullVertical,
    steps: [
      LadderStep(name: 'Assisted pull-up'),
      LadderStep(name: 'Pull-up', visualId: 'pullUp'),
      LadderStep(name: 'Weighted pull-up (backpack/DB)', backpackLoaded: true),
      LadderStep(name: 'Weighted pull-up +pause at top', backpackLoaded: true),
    ],
  ),
  MovementPattern.pullHorizontal: const MovementLadder(
    pattern: MovementPattern.pullHorizontal,
    steps: [
      LadderStep(name: 'DB row', dumbbells: 2),
      LadderStep(
        name: 'Chest-supported row (bolster)',
        dumbbells: 2,
        visualId: 'dumbbellInclineRow',
      ),
      LadderStep(name: 'Single-arm row +pause', dumbbells: 1, unilateral: true),
    ],
  ),
  MovementPattern.kneeHealth: const MovementLadder(
    pattern: MovementPattern.kneeHealth,
    steps: [
      LadderStep(name: 'Backward treadmill'),
      LadderStep(name: 'Tibialis raise'),
      LadderStep(name: 'Calf raises (slant board)'),
      LadderStep(name: 'Reverse step-up'),
    ],
  ),
  MovementPattern.coreGrip: const MovementLadder(
    pattern: MovementPattern.coreGrip,
    steps: [
      LadderStep(
        name: 'Plank',
        metric: ExerciseMetric.seconds,
        targetRange: (20, 60),
      ),
      LadderStep(
        name: 'L-sit progression',
        metric: ExerciseMetric.seconds,
        targetRange: (10, 30),
      ),
      LadderStep(
        name: 'Hanging',
        metric: ExerciseMetric.seconds,
        targetRange: (20, 60),
      ),
      LadderStep(
        name: 'Weighted hanging',
        backpackLoaded: true,
        metric: ExerciseMetric.seconds,
        targetRange: (15, 45),
      ),
      LadderStep(name: 'Wrist curls', dumbbells: 2),
    ],
  ),
};

/// §7.1 named pain substitutes that get their own [ExerciseState] track,
/// keyed as `sub:<pattern>:<slug>`.
class SubstituteExercise {
  final String slug;
  final String name;
  final MovementPattern pattern;
  final int dumbbells;
  final String? visualId;

  /// Bodyweight movement loaded by a backpack/belt (§2.6 rule 5) — e.g. dips.
  /// Progresses on reps at bodyweight, then in free-entered added weight.
  final bool backpackLoaded;

  const SubstituteExercise({
    required this.slug,
    required this.name,
    required this.pattern,
    this.dumbbells = 0,
    this.visualId,
    this.backpackLoaded = false,
  });

  String get trackKey => 'sub:${pattern.name}:$slug';

  /// The ladder step this named exercise resolves to.
  LadderStep get ladderStep => LadderStep(
        name: name,
        visualId: visualId,
        dumbbells: dumbbells,
        backpackLoaded: backpackLoaded,
      );
}

const bridgeHamstringCurl = SubstituteExercise(
  slug: 'bridge_hamstring_curl',
  name: 'Bridge hamstring curl',
  pattern: MovementPattern.hinge,
);

const lightSingleLegRdl = SubstituteExercise(
  slug: 'light_sl_rdl',
  name: 'Light single-leg RDL (bodyweight/12 lb)',
  pattern: MovementPattern.hinge,
  dumbbells: 1,
);

const floorPress = SubstituteExercise(
  slug: 'floor_press',
  name: 'Floor press',
  pattern: MovementPattern.pushHorizontal,
  dumbbells: 2,
);

/// Dedicated low-lumbar-load variants used only while the lower-back
/// recovery mode is active. Separate tracks keep their intentionally
/// constrained prescriptions from advancing the normal loaded ladders.
const lowerBackRecoveryPullUp = SubstituteExercise(
  slug: 'lower_back_pull_up',
  name: 'Pull-up (bodyweight; assisted as needed)',
  pattern: MovementPattern.pullVertical,
  visualId: 'pullUp',
);

const lowerBackRecoveryChestSupportedRow = SubstituteExercise(
  slug: 'lower_back_chest_supported_row',
  name: 'Chest-supported DB row (bolster)',
  pattern: MovementPattern.pullHorizontal,
  dumbbells: 2,
  visualId: 'dumbbellInclineRow',
);

const lowerBackRecoveryDip = SubstituteExercise(
  slug: 'lower_back_bodyweight_dip',
  name: 'Dip (bodyweight)',
  pattern: MovementPattern.pushVertical,
  visualId: 'parallelBarDip',
);

/// §12 travel / no-equipment mode: each pattern's bodyweight resolution.
/// Progression is by reps, hold duration, or ROM only — engine state is not advanced while
/// travelling, but lastTrained still updates so §6.6 doesn't misfire later.
const Map<MovementPattern, LadderStep> travelSteps = {
  MovementPattern.squat: LadderStep(
    name: 'Split squat (bodyweight)',
    visualId: 'bodyweightSplitSquat',
  ),
  MovementPattern.hinge: LadderStep(name: 'Single-leg RDL (bodyweight)'),
  MovementPattern.pushHorizontal: LadderStep(name: 'Push-up', visualId: 'pushUp'),
  MovementPattern.pushVertical: LadderStep(name: 'Pike push-up'),
  MovementPattern.pullVertical: LadderStep(name: 'Prone lat pull-down'),
  MovementPattern.pullHorizontal: LadderStep(name: 'Prone W-row'),
  MovementPattern.coreGrip: LadderStep(
    name: 'Plank / hollow hold',
    metric: ExerciseMetric.seconds,
    targetRange: (20, 45),
  ),
};

// S5 "Flex/Pump" direct accessories (§2.1: arms, shoulders, core). Not spec
// ladders — named single-DB exercises with their own state tracks, reusing
// the substitute mechanism. Pattern choice drives the §7.1 pain mapping:
// coreGrip ties curls to the elbow/wrist "remove direct arm work" rule,
// pushVertical ties raises/triceps to the shoulder rules.
const dbCurl = SubstituteExercise(
  slug: 'db_curl',
  name: 'Alternating DB curl',
  pattern: MovementPattern.coreGrip,
  dumbbells: 1,
  visualId: 'alternatingDumbbellCurl',
);

const lateralRaise = SubstituteExercise(
  slug: 'lateral_raise',
  name: 'Alternating lateral raise',
  pattern: MovementPattern.pushVertical,
  dumbbells: 1,
  visualId: 'oneArmDumbbellLateralRaise',
);

const overheadTriceps = SubstituteExercise(
  slug: 'overhead_triceps',
  name: 'Alternating overhead triceps extension',
  pattern: MovementPattern.pushVertical,
  dumbbells: 1,
);

/// Dips (triceps + chest + front delt) on parallel grips. Loaded with a
/// single dumbbell held between the feet (or in a backpack), so the load
/// steps in real PowerBlock increments instead of the coarse jumps of pure
/// bodyweight — that solves the "can't control dip load" problem. Mapped to
/// pushVertical so a sharp shoulder flag removes it (§7.1), like the overhead
/// work it replaces.
const dip = SubstituteExercise(
  slug: 'dip',
  name: 'Weighted dip (DB between feet)',
  pattern: MovementPattern.pushVertical,
  dumbbells: 1,
  visualId: 'parallelBarDip',
);

/// Named progression tracks that are part of a normal (non-pain) plan.
/// Pain-only substitutes remain in [substituteRegistry], but are created only
/// when their corresponding pain action is actually prescribed.
const s5NamedAccessories = <SubstituteExercise>[
  dbCurl,
  lateralRaise,
  dip,
];

/// No-equipment equivalents for S5's named dumbbell accessories. Keeping
/// their normal track keys means the session still records recency for the
/// intended slot while load-based progression remains frozen in travel mode.
const Map<String, LadderStep> travelNamedSteps = {
  'sub:hinge:bridge_hamstring_curl': LadderStep(name: 'Bridge hamstring curl'),
  'sub:hinge:light_sl_rdl': LadderStep(name: 'Single-leg RDL (bodyweight)'),
  'sub:pushHorizontal:floor_press': LadderStep(
    name: 'Wall push-up (pain-free range)',
  ),
  'sub:pullVertical:lower_back_pull_up': LadderStep(name: 'Prone lat pull-down'),
  'sub:pullHorizontal:lower_back_chest_supported_row': LadderStep(
    name: 'Prone W-row',
  ),
  'sub:pushVertical:lower_back_bodyweight_dip': LadderStep(
    name: 'Bench / chair dip (bodyweight)',
    visualId: 'benchDip',
  ),
  'sub:coreGrip:db_curl': LadderStep(name: 'Self-resisted curl'),
  'sub:pushVertical:lateral_raise': LadderStep(name: 'Prone Y-raise'),
  'sub:pushVertical:overhead_triceps': LadderStep(name: 'Diamond push-up'),
  'sub:pushVertical:dip': LadderStep(
    name: 'Bench / chair dip (bodyweight)',
    visualId: 'benchDip',
  ),
};

/// Keyed by [SubstituteExercise.trackKey] so plan assembly can resolve a
/// substitute's real name/load setup instead of falling back to its
/// underlying pattern's normal ladder (§7.1).
final Map<String, SubstituteExercise> substituteRegistry = {
  for (final s in [
    bridgeHamstringCurl,
    lightSingleLegRdl,
    floorPress,
    lowerBackRecoveryPullUp,
    lowerBackRecoveryChestSupportedRow,
    lowerBackRecoveryDip,
    ...s5NamedAccessories,
  ])
    s.trackKey: s,
};
