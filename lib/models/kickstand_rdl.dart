/// The optional mini-band kickstand RDL: a fixed hinge-and-glute primer at the
/// end of the warm-up on lower-body days. It is a warm-up entry that never
/// progresses, earns stimulus credit, advances a ladder or a Back rebuild stage.
class KickstandRdl {
  const KickstandRdl._();

  static const trackKey = 'warmup:kickstand_rdl';

  /// Slow reps on each leg per round.
  static const repsPerSide = 8;

  static bool isTrack(String key) => key == trackKey;
}
