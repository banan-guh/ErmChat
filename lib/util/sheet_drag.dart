/// Drag-to-close logic for sheets. Closes below [sheetCloseFraction] height or faster than [sheetCloseVelocity] px/s.
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
