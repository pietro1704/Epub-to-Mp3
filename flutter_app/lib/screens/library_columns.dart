/// User-chosen library density (Apple #1429): 1..8 columns, remembered, and
/// capped only by what fits at a 72 dp minimum tile width.
const libraryColumnsPreferenceKey = 'library.requestedColumns.v1';
const libraryColumnChoices = [1, 2, 3, 4, 5, 6, 7, 8];

const _gridPadding = 16.0;
const _gridSpacing = 16.0;
const _minimumTileWidth = 72.0;

/// Columns to draw for [width]. [requested] null keeps the automatic density
/// (2 on phones, wider screens fit more); a requested count wins until the
/// tiles would get narrower than [_minimumTileWidth].
int libraryColumnCount(double width, {int? requested}) {
  if (requested == null) {
    return width < 600 ? 2 : (width / 190).floor().clamp(3, 8);
  }
  final usable = width - 2 * _gridPadding;
  final fitting = ((usable + _gridSpacing) / (_minimumTileWidth + _gridSpacing))
      .floor()
      .clamp(1, 8);
  return requested.clamp(1, 8).clamp(1, fitting);
}

int? readRequestedColumns(Object? stored) =>
    stored is int ? stored.clamp(1, 8) : null;
