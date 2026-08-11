import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 全局主题：深色 Material 3，黑白灰 + 琥珀色 #d9a15c
const Color kAmber = Color(0xFFd9a15c);
const Color kAmberLight = Color(0xFFecc083);
const Color kAmberDark = Color(0xFFb07f3f);
const Color kBg = Color(0xFF111113);
const Color kSurface = Color(0xFF1A1A1C);
const Color kCard = Color(0xFF202023);
const Color kBorder = Color(0xFF2E2E33);
const Color kMuted = Color(0xFF9E9EA6);

const LinearGradient kAmberGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [kAmberDark, kAmber, kAmberLight],
);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kAmber,
    brightness: Brightness.dark,
    surface: kSurface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: const CardThemeData(
      color: kCard,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: kBorder, width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kCard,
      isDense: true,
      hintStyle: const TextStyle(color: kMuted),
      prefixIconColor: kMuted,
      suffixIconColor: kMuted,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: kAmber, width: 1.2),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: kAmber,
        foregroundColor: Colors.black,
        minimumSize: const Size.fromHeight(50),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kAmber),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kAmber,
        side: const BorderSide(color: kAmber),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: kAmber),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kSurface.withValues(alpha: 0.96),
      indicatorColor: kAmber.withValues(alpha: 0.18),
      elevation: 0,
      height: 64,
      labelTextStyle: const WidgetStatePropertyAll(
        TextStyle(fontSize: 12, color: Colors.white),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? kAmber : kMuted,
        ),
      ),
    ),
    dividerTheme: const DividerThemeData(color: kBorder, thickness: 0.5),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xFF26262A),
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: kSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}

/// 背景光晕：深色底 + 顶部琥珀光晕 + 底部冷蓝光晕（克制）
class GlowBackground extends StatelessWidget {
  const GlowBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF191920), kBg, Color(0xFF141411)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -140,
            right: -140,
            child: _glow(360, kAmber.withValues(alpha: 0.10)),
          ),
          Positioned(
            bottom: -180,
            left: -160,
            child: _glow(420, const Color(0xFF4A5A7A).withValues(alpha: 0.10)),
          ),
          Positioned(
            top: MediaQuery.of(context).size.height * 0.30,
            left: -200,
            child: _glow(340, kAmber.withValues(alpha: 0.05)),
          ),
          ?child,
        ],
      ),
    );
  }

  Widget _glow(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, Colors.transparent],
        ),
      ),
    );
  }
}

/// 圆角渐变进度条
class GradientBar extends StatelessWidget {
  const GradientBar({
    super.key,
    required this.value,
    this.height = 8,
    this.borderRadius = 4,
  });

  final double value;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2E),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: value.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            gradient: kAmberGradient,
            borderRadius: BorderRadius.circular(borderRadius),
          ),
        ),
      ),
    );
  }
}
