/// Stable identities for the prescribed HOV Phase 1 foot routine. The entries
/// are real exercise exposure, but never progression tracks or main lift sets.
class HovFootWarmup {
  const HovFootWarmup._();

  static const bridge = 'hov:calf_bridge';
  static const roll = 'hov:foot_roll';
  static const hinge = 'hov:floating_heel_hinge';
  static const lifts = 'hov:inversion_eversion_lifts';
  static const steps = 'hov:inversion_eversion_steps';
  static const holdLeft = 'hov:calf_hold_left';
  static const holdRight = 'hov:calf_hold_right';
  static const tracks = {
    bridge,
    roll,
    hinge,
    lifts,
    steps,
    holdLeft,
    holdRight,
  };

  static bool isTrack(String key) => tracks.contains(key);
  static bool isStrengthTrack(String key) =>
      key == bridge || key == holdLeft || key == holdRight;

  /// App pacing estimates, not additional clinical prescriptions. The calf
  /// holds alternate legs, so the opposite leg's hold supplies the rest.
  static int restSecondsAfter(String key) =>
      key == bridge || key == steps ? 30 : 0;
  static int repSeconds(String key) => key == hinge ? 3 : 2;
  static const transitionSeconds = 10;

  static const guidance =
      'Phase 1: mindestens 1 Woche, 1× täglich; bei starkem Muskelkater '
      'alle 2 Tage. Ziel: Schmerz unter 3/10. Bei 3–5/10 Rücksprache, '
      'über 5/10 abbrechen; scharfe oder ausstrahlende Schmerzen stoppen. '
      'Keine automatische Steigerung. Laufumfang mit dem Therapeuten abstimmen.';
}
