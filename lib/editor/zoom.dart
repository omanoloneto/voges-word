/// The editor's smallest zoom.
const smallestZoom = 0.5;

/// The editor's largest zoom. Pictures are decoded for it, so zooming in
/// never decodes them again.
const largestZoom = 2.0;

/// The zooms the ribbon's buttons and the keyboard step through.
const zoomLevels = [
  smallestZoom,
  0.75,
  0.9,
  1.0,
  1.1,
  1.25,
  1.5,
  1.75,
  largestZoom,
];

/// The first of [zoomLevels] above [zoom] when [direction] is 1, or below it
/// when it is -1, so a zoom between levels, as the slider sets, steps to the
/// nearest one that way; null when there is none.
double? nextZoomLevel(double zoom, int direction) => direction > 0
    ? zoomLevels.where((level) => level > zoom + _sameZoom).firstOrNull
    : zoomLevels.where((level) => level < zoom - _sameZoom).lastOrNull;

/// Zooms this close to a level are on it: the slider's carry rounding errors.
const _sameZoom = 0.001;
