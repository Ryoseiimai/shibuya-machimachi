// 色と文字（worker/src/html.js のトークン）。白文字のボタン・バナーは全部 4.5:1 以上（test/core/theme_test.dart）。
import 'package:flutter/material.dart';

abstract final class AppColors {
  /// 主ボタン・h1・距離・選んだチップ・到着表示（白文字で 4.5:1 以上）。
  static const brandOrange = Color(0xFFC8431F);
  static const brandOrangeSoftBg = Color(0xFFFFE6DB);
  static const brandOrangeOnSoft = Color(0xFF8A2A10);
  static const mutedText = Color(0xFF6B5D53);
  static const lineGreen = Color(0xFF028238);
  static const offlineRed = Color(0xFFB3261E);

  static const background = Color(0xFFFFF7F0);
  static const ink = Color(0xFF2A2222);
  static const card = Color(0xFFFFFFFF);
  static const secondaryBg = Color(0xFFEFE4DA);
  static const secondaryText = Color(0xFF5B4C42);
  static const inputBorder = Color(0xFFF0D9CC);
  static const inputFill = Color(0xFFFFFDFB);
  static const readonlyFill = Color(0xFFF6F1EC);
  static const readonlyText = Color(0xFF55483F);
  static const warnBg = Color(0xFFFFF1CC);
  static const warnText = Color(0xFF7A5B00);
  static const judgeIdleBg = Color(0xFFF4EDE6);
  static const divider = Color(0xFFF0E6DC);
  static const mapBg = Color(0xFFE9EEF1);
  static const demoBanner = Color(0xFF2A2222);
  static const arBadgeRed = Color(0xE6E64646);

  // 3D のピン（shibuya3d.mjs）
  static const pinMe = Color(0xFF1E88E5);
  static const pinMeUnderground = Color(0xFF37474F);
  static const pinPartner = Color(0xFFFB8C00);
  static const pinPartnerUnderground = Color(0xFF6A1B9A);
}

abstract final class AppText {
  static const h1 = TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 24 * .04, color: AppColors.brandOrange);
  static const subtitle = TextStyle(fontSize: 13, color: AppColors.mutedText);
  static const hint = TextStyle(fontSize: 13, color: AppColors.mutedText, height: 1.5);
  static const label = TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.ink);
  static const body = TextStyle(fontSize: 16, color: AppColors.ink, height: 1.6);
  static const button = TextStyle(fontSize: 17, fontWeight: FontWeight.w800);
  static const distance = TextStyle(fontSize: 52, fontWeight: FontWeight.w900, color: AppColors.brandOrange);
  static const distanceUnit = TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.brandOrange);
  static const judge = TextStyle(fontSize: 20, fontWeight: FontWeight.w800);
  static const routeInstruction = TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.ink);
  static const badge = TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppColors.brandOrangeOnSoft);
  static const small = TextStyle(fontSize: 12, color: AppColors.mutedText);
  static const attribution = TextStyle(fontSize: 11, color: AppColors.mutedText, height: 1.5);
}

/// 画面の最大幅（Web 版の main と同じ 480px）。
const double kContentMaxWidth = 480;

ThemeData buildAppTheme() {
  const scheme = ColorScheme.light(
    primary: AppColors.brandOrange,
    onPrimary: Colors.white,
    secondary: AppColors.secondaryBg,
    onSecondary: AppColors.secondaryText,
    surface: AppColors.card,
    onSurface: AppColors.ink,
    error: AppColors.offlineRed,
    onError: Colors.white,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  const padding = EdgeInsets.symmetric(vertical: 14, horizontal: 18);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    textTheme: const TextTheme(bodyMedium: AppText.body, bodyLarge: AppText.body, labelLarge: AppText.button),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.brandOrange,
        foregroundColor: Colors.white,
        textStyle: AppText.button,
        padding: padding,
        minimumSize: const Size.fromHeight(52),
        shape: shape,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.secondaryBg,
        foregroundColor: AppColors.secondaryText,
        elevation: 0,
        textStyle: AppText.button,
        padding: padding,
        minimumSize: const Size.fromHeight(52),
        shape: shape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.inputFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.inputBorder, width: 2)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.inputBorder, width: 2)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.brandOrange, width: 2)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: AppColors.ink),
  );
}

/// WCAG 2.x のコントラスト比。
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
