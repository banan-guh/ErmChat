/// Shared sheet drag-to-close decision for the inline panels (thread,
/// mentions) and the emote menu. A release below [sheetCloseFraction] of the
/// sheet's max height closes it; a fling faster than [sheetCloseVelocity]
/// px/s closes it regardless of position.
const double sheetCloseFraction = 0.85;
const double sheetCloseVelocity = 200.0;

bool shouldCloseSheet({
  required double fraction,
  required double velocity,
  double closeFraction = sheetCloseFraction,
  double closeVelocity = sheetCloseVelocity,
}) {
  return fraction < closeFraction || velocity > closeVelocity;
}
