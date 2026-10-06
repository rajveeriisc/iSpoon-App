// temperature_format.dart — ONE definition of how a spoon temperature is
// rendered as text.
//
// WHY THIS EXISTS
// The number on the spoon's own OLED and the number in the app must match. A
// user looking at both at the same time reads a mismatch as a bug, and they
// are right to: it is the same sensor reading.
//
// The firmware displays a whole number (its big font has a fixed 5-glyph field
// "25 oC"), and it decides that whole number itself. The app previously used
// `toStringAsFixed(0)`, which ROUNDS — so a reading of 25.7 showed as 26 in
// the app while the spoon showed 25. Truncating instead means the digits after
// the decimal point never change the number shown, which is the behaviour the
// display has.
//
// Keep every user-facing temperature going through here. If the firmware's
// rounding is ever confirmed to differ, this is the single place to change.
library;

/// Whole-degree text for a spoon temperature, matching the spoon's display.
///
/// Truncates toward zero: what comes after the decimal point never moves the
/// digit. `25.9 -> "25"`, `-3.9 -> "-3"`.
String formatSpoonTempC(double celsius) => celsius.truncate().toString();

/// Same, with the degree suffix: `"25°C"`.
String formatSpoonTempWithUnit(double celsius) => '${formatSpoonTempC(celsius)}°C';
