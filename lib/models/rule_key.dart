/// §9.6 closed rule-key enum. The AI layer may reference only fired keys
/// from this list - never invent free-form rationale.
enum RuleKey {
  restTimeZero,
  restDoubleRed,
  norwegian4x4Due,
  rehitFallbackDue,
  baseLongDeficit,
  // Retained solely so persisted DecisionTrace history remains readable.
  baseShortDeficit,
  muscleStimulusDeficit,
  muscleRecoveryDemotion,
  muscleOverMaxDemotion,
  recoverySwapEasyCardio,
  easyRecoveryCardio,
  manualSessionOverride,

  // Legacy v1 keys remain deserializable for saved DecisionTrace history.
  // Decision Engine v2 does not emit the floor/weekend/recency keys below.
  floorForceStrength,
  floorForceIntensity,
  floorSoftBoost,
  legheavyDemoted,
  legheavyBacktobackVolumecut,
  recencyBoost,
  queueNext,
  s6WeekendRule,
  s7TimeSub,
  s7SecondSessionOffer,
  yellowVolumeCut,
  yellow4x4ToRehit,
  redSwapTechnique,
  redSwapZ2,
  timeCompress60_35,
  timeCompress35_20,
  travelModeActive,
  lowerBackRecoveryActive,
  lowerBackRecoverySpacing,
  lowerBackRecoveryReentry,
  painSubMild,
  painSubSharp,
  painFreeze,
  painMedicalEscalation,
  urgentMedicalAssessment,
  painReentryTest,
  deloadActive,
  detrainAdjust,
  capLadderJump,
  onboardSubstitute,
  illnessGuard,
  subjOverrideDown,
  subjOverrideUpBlocked,
}

extension RuleKeyCode on RuleKey {
  /// Whether this key takes a `<pattern>` insertion (e.g. RECENCY_BOOST_SQUAT).
  bool get isPatternParameterized => switch (this) {
        RuleKey.recencyBoost ||
        RuleKey.painSubMild ||
        RuleKey.painSubSharp ||
        RuleKey.painFreeze ||
        RuleKey.painMedicalEscalation ||
        RuleKey.painReentryTest ||
        RuleKey.deloadActive ||
        RuleKey.detrainAdjust ||
        RuleKey.capLadderJump =>
          true,
        _ => false,
      };

  /// Renders the exact closed-enum wire string, e.g. `PAIN_SUB_HINGE_SHARP`.
  String code({String? pattern}) {
    final p = pattern?.toUpperCase();
    switch (this) {
      case RuleKey.restTimeZero:
        return 'REST_TIME_ZERO';
      case RuleKey.restDoubleRed:
        return 'REST_DOUBLE_RED';
      case RuleKey.norwegian4x4Due:
        return 'NORWEGIAN_4X4_DUE';
      case RuleKey.rehitFallbackDue:
        return 'REHIT_FALLBACK_DUE';
      case RuleKey.baseLongDeficit:
        return 'BASE_LONG_DEFICIT';
      case RuleKey.baseShortDeficit:
        return 'BASE_SHORT_DEFICIT';
      case RuleKey.muscleStimulusDeficit:
        return 'MUSCLE_STIMULUS_DEFICIT';
      case RuleKey.muscleRecoveryDemotion:
        return 'MUSCLE_RECOVERY_DEMOTION';
      case RuleKey.muscleOverMaxDemotion:
        return 'MUSCLE_OVER_MAX_DEMOTION';
      case RuleKey.recoverySwapEasyCardio:
        return 'RECOVERY_SWAP_EASY_CARDIO';
      case RuleKey.easyRecoveryCardio:
        return 'EASY_RECOVERY_CARDIO';
      case RuleKey.manualSessionOverride:
        return 'MANUAL_SESSION_OVERRIDE';
      case RuleKey.floorForceStrength:
        return 'FLOOR_FORCE_STRENGTH';
      case RuleKey.floorForceIntensity:
        return 'FLOOR_FORCE_INTENSITY';
      case RuleKey.floorSoftBoost:
        return 'FLOOR_SOFT_BOOST';
      case RuleKey.legheavyDemoted:
        return 'LEGHEAVY_DEMOTED';
      case RuleKey.legheavyBacktobackVolumecut:
        return 'LEGHEAVY_BACKTOBACK_VOLUMECUT';
      case RuleKey.recencyBoost:
        return 'RECENCY_BOOST_$p';
      case RuleKey.queueNext:
        return 'QUEUE_NEXT';
      case RuleKey.s6WeekendRule:
        return 'S6_WEEKEND_RULE';
      case RuleKey.s7TimeSub:
        return 'S7_TIME_SUB';
      case RuleKey.s7SecondSessionOffer:
        return 'S7_SECOND_SESSION_OFFER';
      case RuleKey.yellowVolumeCut:
        return 'YELLOW_VOLUME_CUT';
      case RuleKey.yellow4x4ToRehit:
        return 'YELLOW_4X4_TO_REHIT';
      case RuleKey.redSwapTechnique:
        return 'RED_SWAP_TECHNIQUE';
      case RuleKey.redSwapZ2:
        return 'RED_SWAP_Z2';
      case RuleKey.timeCompress60_35:
        return 'TIME_COMPRESS_60_35';
      case RuleKey.timeCompress35_20:
        return 'TIME_COMPRESS_35_20';
      case RuleKey.travelModeActive:
        return 'TRAVEL_MODE_ACTIVE';
      case RuleKey.lowerBackRecoveryActive:
        return 'LOWER_BACK_RECOVERY_ACTIVE';
      case RuleKey.lowerBackRecoverySpacing:
        return 'LOWER_BACK_RECOVERY_SPACING';
      case RuleKey.lowerBackRecoveryReentry:
        return 'LOWER_BACK_RECOVERY_REENTRY';
      case RuleKey.painSubMild:
        return 'PAIN_SUB_${p}_MILD';
      case RuleKey.painSubSharp:
        return 'PAIN_SUB_${p}_SHARP';
      case RuleKey.painFreeze:
        return 'PAIN_FREEZE_$p';
      case RuleKey.painMedicalEscalation:
        return 'PAIN_MEDICAL_ESCALATION_$p';
      case RuleKey.urgentMedicalAssessment:
        return 'URGENT_MEDICAL_ASSESSMENT';
      case RuleKey.painReentryTest:
        return 'PAIN_REENTRY_TEST_$p';
      case RuleKey.deloadActive:
        return 'DELOAD_ACTIVE_$p';
      case RuleKey.detrainAdjust:
        return 'DETRAIN_ADJUST_$p';
      case RuleKey.capLadderJump:
        return 'CAP_LADDER_JUMP_$p';
      case RuleKey.onboardSubstitute:
        return 'ONBOARD_SUBSTITUTE';
      case RuleKey.illnessGuard:
        return 'ILLNESS_GUARD';
      case RuleKey.subjOverrideDown:
        return 'SUBJ_OVERRIDE_DOWN';
      case RuleKey.subjOverrideUpBlocked:
        return 'SUBJ_OVERRIDE_UP_BLOCKED';
    }
  }
}

/// One entry in `DecisionTrace.firedRules`. `params` carries whatever the
/// fallback template / AI glossary needs to render human text (session
/// names, numbers, substitute names) without the model inventing anything.
class FiredRule {
  final RuleKey key;
  final String? pattern;
  final Map<String, String> params;

  const FiredRule(this.key, {this.pattern, this.params = const {}});

  String get code => key.code(pattern: pattern);

  @override
  String toString() => code;
}
