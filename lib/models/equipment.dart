/// §2.6 equipment specification - the user's actual PowerBlocks.
class DumbbellBlock {
  final String id;
  final String label;

  /// Achievable weight steps per single dumbbell, in lb, ascending.
  final List<double> perDumbbellSteps;

  const DumbbellBlock({
    required this.id,
    required this.label,
    required this.perDumbbellSteps,
  });
}

/// Ships pre-filled with the user's actual blocks (§2.6).
const smallPowerBlock = DumbbellBlock(
  id: 'small',
  label: 'small',
  perDumbbellSteps: [6, 9, 12, 15, 18, 21, 24],
);

const largePowerBlock = DumbbellBlock(
  id: 'large',
  label: 'large',
  perDumbbellSteps: [10, 15, 20, 25, 30, 35, 40, 45, 50],
);

class EquipmentConfig {
  final List<DumbbellBlock> blocks;
  final bool unevenPairModeEnabled;

  const EquipmentConfig({
    this.blocks = const [smallPowerBlock, largePowerBlock],
    this.unevenPairModeEnabled = false,
  });

  EquipmentConfig copyWith({List<DumbbellBlock>? blocks, bool? unevenPairModeEnabled}) {
    return EquipmentConfig(
      blocks: blocks ?? this.blocks,
      unevenPairModeEnabled: unevenPairModeEnabled ?? this.unevenPairModeEnabled,
    );
  }
}
