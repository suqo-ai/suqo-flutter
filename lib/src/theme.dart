// Every colour, radius and spacing value the sheet chrome uses.
//
// The only module in this package that holds a hex. The chrome deliberately stays small and
// neutral: the payment block itself is rendered by the SUQO checkout page inside the
// WebView, which brings its own styling, and a second visual language wrapped around it
// would read as two products stacked.

import 'package:flutter/material.dart';

/// SUQO primary. Spinner and the retry action.
const Color kSuqoPrimary = Color(0xFF635BFF);

/// Sheet ground.
const Color kSuqoSurface = Color(0xFFFFFFFF);

/// Headings and the seller's name.
const Color kSuqoText = Color(0xFF0D062D);

/// Secondary copy.
const Color kSuqoMuted = Color(0xFF667080);

/// Hairline under the header.
const Color kSuqoBorder = Color(0xFFEAEAEA);

/// Corner radius on the one button this package draws.
const double kSuqoButtonRadius = 10;

const double kSuqoSpaceXs = 4;
const double kSuqoSpaceSm = 8;
const double kSuqoSpaceMd = 12;
const double kSuqoSpaceLg = 16;
const double kSuqoSpaceXl = 24;
