// app_theme.dart — centralized design system (colors, gradients, ThemeData).
//
// Static-only class that defines the app's visual language. SmartSpoon uses one
// cyan-teal brand accent, cool neutral surfaces, a 4-point spacing grid, and
// semantic warning/error colors only when the data requires them.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // ─── Brand palette ────────────────────────────────────────────────────────
  static const primary = Color(0xFF0E7490);
  static const primaryDeep = Color(0xFF07566B);
  static const primaryOnDark = Color(0xFF67C7DB);
  static const primaryOnDarkInk = Color(0xFF062F38);
  static const brandTint = Color(0xFFE4F3F7);
  static const brandTintStrong = Color(0xFFCDE9F0);
  static const darkBrandSurface = Color(0xFF123A46);

  // Kept as aliases for compatibility. Decorative secondary/tertiary accents
  // intentionally resolve to the same brand family.
  static const secondary = primary;
  static const tertiary = primary;

  /// Semantic success only (validation ticks, healthy ranges). Deliberately a
  /// muted teal, NOT the old emerald — green is now the exception, not the
  /// default surface colour.
  static const success = Color(0xFF0F766E);

  static const emerald = primary;
  static const accentGreen = primary;
  static const accentGreenBg = brandTint;

  // ─── Light Mode Background — very light, faintly blue ─────────────────────
  static const canvas = Color(0xFFF5FAFC);
  static const oat = Color(0xFFE9F3F8);
  static const bgTop = Color(0xFFFBFDFE);
  static const bgBottom = Color(0xFFEDF5FA);
  static const surface = Colors.white;
  static const bg = Color(0xFFF5FAFC);

  // Legacy decorative card names all resolve to one branded surface.
  static const cardTeal = brandTint;
  static const cardBlue = brandTint;
  static const cardPurple = brandTint;
  static const cardAmber = brandTint;
  static const cardGreen = brandTint;
  static const cardOrange = brandTint;
  static const cardPink = brandTint;
  static const cardIndigo = brandTint;
  static const cardCoral = Color(0xFFFFEBEE); // Coral tint
  static const cardMint = brandTint;

  static const richTeal = primary;
  static const richPurple = primary;
  static const richAmber = primary;
  static const richBlue = primary;
  static const richGreen = primary;
  static const richOrange = primary;
  static const richPink = primary;
  static const richIndigo = primary;

  // ─── Text — cool slate, no green cast ─────────────────────────────────────
  // Contrast on white / on canvas:
  //   textPrimary   14.30 / 13.60      textSecondary  6.20 / 5.89
  //   textTertiary   5.21 /  4.96  ← was #70837F at 4.09, below AA for body
  static const textDark = Color(0xFF0F2E38);
  static const textLight = Color(0xFF4A6570);
  static const textPrimary = Color(0xFF0F2E38);
  static const textSecondary = Color(0xFF4A6570);
  static const textTertiary = Color(0xFF5A7079);

  // ─── Borders & Shadows ────────────────────────────────────────────────────
  static const border = Color(0xFFD8E6ED);
  static const line = Color(0xFFE4EEF3);
  static const cardShadow = Color(0x140E7490);

  // Layout tokens: a 4-point grid, consistent radii, and accessible targets.
  static const spaceXs = 4.0;
  static const spaceSm = 8.0;
  static const spaceMd = 16.0;
  static const spaceLg = 24.0;
  static const spaceXl = 32.0;
  static const radiusSm = 12.0;
  static const radiusMd = 16.0;
  static const radiusLg = 20.0;
  static const radiusXl = 28.0;
  static const minTouchTarget = 48.0;
  static const authContentMaxWidth = 440.0;

  // ─── Legacy color aliases (kept for backward compat) ──────────────────────
  static const cream = surface;
  static const sage = primary;
  static const sageDeep = primary;
  static const honey = primary;
  static const paprika = Color(0xFFE15B5B);
  static const caramel = primary;
  static const amber = Color(0xFFF59E0B);
  static const gold = Color(0xFFFBBF24);
  static const rose = Color(0xFFE11D48);
  static const coral = Color(0xFFE11D48);
  static const roast = Color(0xFF4A3424);
  static const roastSoft = Color(0xFF8B7355);

  // ─── Dark Mode — neutral slate-blue, lifted off near-black ────────────────
  //
  // Was a very dark GREEN-black (#07110F bg, #101C1A surface): both too dark to
  // separate surfaces from background, and visibly green-tinted. Material's dark
  // guidance is a lifted neutral surface (~#121212+) with desaturated accents,
  // not a saturated hue darkened to near-black.
  //
  // Contrast on the new surface #18222C:
  //   darkText #E8EFF4 13.87   darkSubText #A8B8C4 7.91
  //   primary  #4FC3D9  7.78   success     #5FD3BE 8.86
  // Surface/background separation 1.12 — visible without a border.
  static const darkBg = Color(0xFF0F1720);
  static const darkSurface = Color(0xFF18222C);
  static const darkText = Color(0xFFE8EFF4);
  static const darkSubText = Color(0xFFA8B8C4);

  static const darkCardTeal = darkBrandSurface;
  static const darkCardBlue = darkBrandSurface;
  static const darkCardPurple = darkBrandSurface;
  static const darkCardAmber = darkBrandSurface;
  static const darkCardGreen = darkBrandSurface;
  static const darkCardOrange = darkBrandSurface;
  static const darkCardPink = darkBrandSurface;
  static const darkCardIndigo = darkBrandSurface;

  // Legacy dark aliases
  static const darkCanvas = Color(0xFF0F1720);
  static const darkCream = Color(0xFF1B2530);
  static const darkCreamElevated = Color(0xFF222E3A);
  static const darkSurfaceCard = Color(0xFF18222C);
  static const darkBorder = Color(0xFF2C3A47);
  static const darkTextPrimary = Color(0xFFE8EFF4);
  static const darkTextSecondary = Color(0xFFA8B8C4);
  static const darkTextTertiary = Color(0xFF8496A4);
  static const darkRose = Color(0xFFFB7185);
  static const darkSageDeepAccent = primaryOnDark;

  // ─── Gradients ─────────────────────────────────────────────────────────────
  static LinearGradient get backgroundGradient => const LinearGradient(
    colors: [bgTop, bgBottom],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static LinearGradient get darkBackgroundGradient => LinearGradient(
    colors: [darkBg, darkSurface.withValues(alpha: 0.95)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static LinearGradient get headerGradient => const LinearGradient(
    colors: [primary, primaryDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static LinearGradient get primaryGradient => headerGradient;

  static LinearGradient get accentGradient => const LinearGradient(
    colors: [primary, primaryDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static LinearGradient get healthGradient => const LinearGradient(
    colors: [primary, primaryDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static LinearGradient get premiumGradient => const LinearGradient(
    colors: [primary, primaryDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static LinearGradient get warmGradient => const LinearGradient(
    colors: [primary, primaryDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static LinearGradient get mistBackgroundGradient => const LinearGradient(
    colors: [bg, Colors.white],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // ─── Card Decorations ──────────────────────────────────────────────────────
  static BoxDecoration cardDecoration(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: isDark ? darkSurface : surface,
      borderRadius: BorderRadius.circular(radiusLg),
      border: Border.all(color: isDark ? darkBorder : line),
      boxShadow: isDark
          ? null
          : const [
              BoxShadow(
                color: cardShadow,
                blurRadius: 14,
                offset: Offset(0, 5),
              ),
            ],
    );
  }

  static BoxDecoration coloredCardDecoration(
    BuildContext context,
    Color color,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radiusLg),
      boxShadow: [
        BoxShadow(
          color: isDark
              ? Colors.black.withValues(alpha: 0.5)
              : color.withValues(alpha: 0.15), // Reduced opacity
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ],
    );
  }

  // Gradient card with glow
  static BoxDecoration gradientCardDecoration(
    BuildContext context,
    LinearGradient gradient,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      gradient: gradient,
      borderRadius: BorderRadius.circular(radiusLg),
      boxShadow: [
        BoxShadow(
          color: isDark
              ? Colors.black.withValues(alpha: 0.5)
              : gradient.colors.first.withValues(alpha: 0.2), // Reduced glow
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
      ],
    );
  }

  // ─── Typography helpers ────────────────────────────────────────────────────
  static TextStyle serif({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    return GoogleFonts.figtree(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  static TextStyle sans({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    return GoogleFonts.figtree(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  // ─── ThemeData ─────────────────────────────────────────────────────────────
  static ThemeData get lightTheme {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme(
        brightness: Brightness.light,
        primary: primary,
        onPrimary: Colors.white,
        primaryContainer: brandTint,
        onPrimaryContainer: primaryDeep,
        secondary: primary,
        onSecondary: Colors.white,
        secondaryContainer: brandTint,
        onSecondaryContainer: primaryDeep,
        tertiary: primary,
        onTertiary: Colors.white,
        tertiaryContainer: brandTint,
        onTertiaryContainer: primaryDeep,
        error: Color(0xFFE11D48),
        onError: Colors.white,
        errorContainer: cardCoral,
        onErrorContainer: Color(0xFF7F0020),
        surface: surface,
        onSurface: textPrimary,
        surfaceContainerHighest: Color(0xFFEEF4F6),
        outline: border,
        outlineVariant: line,
        shadow: cardShadow,
        scrim: Color(0x52000000),
        inverseSurface: Color(0xFF17323C),
        onInverseSurface: Color(0xFFF2F8FA),
        inversePrimary: primaryOnDark,
        surfaceTint: primary,
      ),
      scaffoldBackgroundColor: canvas,
      textTheme: GoogleFonts.figtreeTextTheme().copyWith(
        displayLarge: GoogleFonts.figtree(
          fontSize: 48,
          height: 1.05,
          letterSpacing: -1.2,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        displayMedium: GoogleFonts.figtree(
          fontSize: 40,
          height: 1.08,
          letterSpacing: -0.9,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        displaySmall: GoogleFonts.figtree(
          fontSize: 34,
          height: 1.1,
          letterSpacing: -0.7,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        headlineLarge: GoogleFonts.figtree(
          fontSize: 32,
          height: 1.12,
          letterSpacing: -0.6,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        headlineMedium: GoogleFonts.figtree(
          fontSize: 28,
          height: 1.16,
          letterSpacing: -0.4,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        headlineSmall: GoogleFonts.figtree(
          fontSize: 24,
          height: 1.2,
          letterSpacing: -0.25,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        titleLarge: GoogleFonts.figtree(
          fontSize: 20,
          height: 1.25,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        titleMedium: GoogleFonts.figtree(
          fontSize: 16,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        titleSmall: GoogleFonts.figtree(
          fontSize: 14,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        bodyLarge: GoogleFonts.figtree(
          fontSize: 16,
          height: 1.5,
          fontWeight: FontWeight.w400,
          color: textPrimary,
        ),
        bodyMedium: GoogleFonts.figtree(
          fontSize: 14,
          height: 1.45,
          fontWeight: FontWeight.w400,
          color: textSecondary,
        ),
        bodySmall: GoogleFonts.figtree(
          fontSize: 12,
          height: 1.4,
          fontWeight: FontWeight.w400,
          color: textTertiary,
        ),
        labelLarge: GoogleFonts.figtree(
          fontSize: 15,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        labelMedium: GoogleFonts.figtree(
          fontSize: 13,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: textSecondary,
        ),
        labelSmall: GoogleFonts.figtree(
          fontSize: 12,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: textTertiary,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          side: const BorderSide(color: line),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 6),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: const Size(minTouchTarget, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: GoogleFonts.figtree(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(minTouchTarget, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: GoogleFonts.figtree(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: const BorderSide(color: primary, width: 1.5),
          minimumSize: const Size(minTouchTarget, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: GoogleFonts.figtree(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: rose),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: rose, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        hintStyle: GoogleFonts.figtree(color: textTertiary, fontSize: 14),
      ),
      dividerTheme: const DividerThemeData(
        color: border,
        thickness: 1,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: cardTeal,
        labelStyle: const TextStyle(
          color: primary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: primary,
        unselectedItemColor: textTertiary,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: cardTeal,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            );
          }
          return const TextStyle(color: textTertiary, fontSize: 12);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: primary, size: 24);
          }
          return const IconThemeData(color: textTertiary, size: 24);
        }),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: CircleBorder(),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : textTertiary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? primary : border,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? primary : textTertiary,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: cardTeal,
        circularTrackColor: cardTeal,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF17302C),
        contentTextStyle: GoogleFonts.figtree(
          color: Colors.white,
          fontSize: 14,
          height: 1.4,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return base;
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme(
        brightness: Brightness.dark,
        primary: primaryOnDark,
        onPrimary: primaryOnDarkInk,
        primaryContainer: darkBrandSurface,
        onPrimaryContainer: Color(0xFFC6EFF7),
        secondary: primaryOnDark,
        onSecondary: primaryOnDarkInk,
        secondaryContainer: darkBrandSurface,
        onSecondaryContainer: Color(0xFFC6EFF7),
        tertiary: primaryOnDark,
        onTertiary: primaryOnDarkInk,
        tertiaryContainer: darkBrandSurface,
        onTertiaryContainer: Color(0xFFC6EFF7),
        error: Color(0xFFFFB4AB),
        onError: Color(0xFF690005),
        errorContainer: Color(0xFF93000A),
        onErrorContainer: Color(0xFFFFDAD6),
        surface: darkSurface,
        onSurface: darkTextPrimary,
        surfaceContainerHighest: Color(0xFF222E3A),
        outline: darkBorder,
        outlineVariant: Color(0xFF24313C),
        shadow: Colors.black,
        scrim: Color(0x99000000),
        inverseSurface: Color(0xFFDDE7EE),
        onInverseSurface: Color(0xFF17252E),
        inversePrimary: primary,
        surfaceTint: primaryOnDark,
      ),
      scaffoldBackgroundColor: darkBg,
      textTheme: GoogleFonts.figtreeTextTheme(ThemeData.dark().textTheme)
          .copyWith(
            displayLarge: GoogleFonts.figtree(
              fontSize: 48,
              height: 1.05,
              letterSpacing: -1.2,
              fontWeight: FontWeight.w700,
              color: darkTextPrimary,
            ),
            displayMedium: GoogleFonts.figtree(
              fontSize: 40,
              height: 1.08,
              letterSpacing: -0.9,
              fontWeight: FontWeight.w700,
              color: darkTextPrimary,
            ),
            displaySmall: GoogleFonts.figtree(
              fontSize: 34,
              height: 1.1,
              letterSpacing: -0.7,
              fontWeight: FontWeight.w700,
              color: darkTextPrimary,
            ),
            headlineLarge: GoogleFonts.figtree(
              fontSize: 32,
              height: 1.12,
              letterSpacing: -0.6,
              fontWeight: FontWeight.w700,
              color: darkTextPrimary,
            ),
            headlineMedium: GoogleFonts.figtree(
              fontSize: 28,
              height: 1.16,
              letterSpacing: -0.4,
              fontWeight: FontWeight.w700,
              color: darkTextPrimary,
            ),
            headlineSmall: GoogleFonts.figtree(
              fontSize: 24,
              height: 1.2,
              letterSpacing: -0.25,
              fontWeight: FontWeight.w600,
              color: darkTextPrimary,
            ),
            titleLarge: GoogleFonts.figtree(
              fontSize: 20,
              height: 1.25,
              fontWeight: FontWeight.w700,
              color: darkTextPrimary,
            ),
            titleMedium: GoogleFonts.figtree(
              fontSize: 16,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: darkTextPrimary,
            ),
            titleSmall: GoogleFonts.figtree(
              fontSize: 14,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: darkTextPrimary,
            ),
            bodyLarge: GoogleFonts.figtree(
              fontSize: 16,
              height: 1.5,
              fontWeight: FontWeight.w400,
              color: darkTextPrimary,
            ),
            bodyMedium: GoogleFonts.figtree(
              fontSize: 14,
              height: 1.45,
              fontWeight: FontWeight.w400,
              color: darkSubText,
            ),
            bodySmall: GoogleFonts.figtree(
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w400,
              color: darkTextTertiary,
            ),
            labelLarge: GoogleFonts.figtree(
              fontSize: 15,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: darkTextPrimary,
            ),
            labelMedium: GoogleFonts.figtree(
              fontSize: 13,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: darkTextSecondary,
            ),
            labelSmall: GoogleFonts.figtree(
              fontSize: 12,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: darkTextTertiary,
            ),
          ),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: darkTextPrimary),
        titleTextStyle: TextStyle(
          color: darkTextPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: const CardThemeData(
        color: darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusLg)),
          side: BorderSide(color: darkBorder),
        ),
        margin: EdgeInsets.symmetric(horizontal: 0, vertical: 6),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryOnDark,
          foregroundColor: primaryOnDarkInk,
          elevation: 0,
          minimumSize: const Size(minTouchTarget, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: GoogleFonts.figtree(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryOnDark,
          foregroundColor: primaryOnDarkInk,
          minimumSize: const Size(minTouchTarget, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: GoogleFonts.figtree(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryOnDark,
          side: const BorderSide(color: primaryOnDark, width: 1.5),
          minimumSize: const Size(minTouchTarget, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: GoogleFonts.figtree(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurfaceCard,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: primaryOnDark, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: darkRose),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: darkRose, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        hintStyle: GoogleFonts.figtree(color: darkTextTertiary, fontSize: 14),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: darkSurface,
        selectedItemColor: primaryOnDark,
        unselectedItemColor: darkTextTertiary,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: darkSurface,
        indicatorColor: darkBrandSurface,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: primaryOnDark, size: 24);
          }
          return const IconThemeData(color: darkTextTertiary, size: 24);
        }),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primaryOnDarkInk
              : darkTextSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primaryOnDark
              : darkBorder,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primaryOnDark
              : darkTextTertiary,
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryOnDark,
        foregroundColor: primaryOnDarkInk,
        elevation: 2,
        shape: CircleBorder(),
      ),
      dividerTheme: const DividerThemeData(
        color: darkBorder,
        thickness: 1,
        space: 1,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: primaryOnDark,
        linearTrackColor: darkBrandSurface,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF20313B),
        contentTextStyle: GoogleFonts.figtree(
          color: Colors.white,
          fontSize: 14,
          height: 1.4,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
