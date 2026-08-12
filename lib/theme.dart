import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式持久化（与 Web 一致键名 admin_theme，值 dark/light）
const kThemeKey = 'admin_theme';

class ThemePrefs {
  ThemePrefs._();

  static final ValueNotifier<Brightness> brightness =
      ValueNotifier<Brightness>(Brightness.dark);

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    brightness.value = sp.getString(kThemeKey) == 'light'
        ? Brightness.light
        : Brightness.dark;
  }

  static Future<void> toggle() async {
    final next = brightness.value == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    brightness.value = next;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(kThemeKey, next == Brightness.light ? 'light' : 'dark');
  }
}
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.card,
    required this.border,
    required this.fg,
    required this.muted,
    required this.accent,
    required this.accentSoft,
    required this.accentBorder,
    required this.danger,
    required this.warn,
    required this.ok,
    required this.codeBg,
    required this.overlay,
  });

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color card;
  final Color border;
  final Color fg;
  final Color muted;
  final Color accent;
  final Color accentSoft;
  final Color accentBorder;
  final Color danger;
  final Color warn;
  final Color ok;
  final Color codeBg;
  final Color overlay;

  static const dark = AppColors(
    bg: Color(0xFF1C1917),
    surface: Color(0xFF262220),
    surface2: Color(0xFF292524),
    card: Color(0xFF262220),
    border: Color(0xFF44403C),
    fg: Color(0xFFFAFAF9),
    muted: Color(0xFFA8A29E),
    accent: Color(0xFFD97706),
    accentSoft: Color(0x1AD97706),
    accentBorder: Color(0x66D97706),
    danger: Color(0xFFF87171),
    warn: Color(0xFFD97706),
    ok: Color(0xFF4ADE80),
    codeBg: Color(0xFF1F1C1A),
    overlay: Color(0x8C000000),
  );

  static const light = AppColors(
    bg: Color(0xFFFAFAF9),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF5F5F4),
    card: Color(0xFFFFFFFF),
    border: Color(0xFFD6D3D1),
    fg: Color(0xFF1C1917),
    muted: Color(0xFF78716C),
    accent: Color(0xFFB45309),
    accentSoft: Color(0x0FB45309),
    accentBorder: Color(0x59B45309),
    danger: Color(0xFFDC2626),
    warn: Color(0xFFD97706),
    ok: Color(0xFF15803D),
    codeBg: Color(0xFFF5F5F4),
    overlay: Color(0x59000000),
  );

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? surface2,
    Color? card,
    Color? border,
    Color? fg,
    Color? muted,
    Color? accent,
    Color? accentSoft,
    Color? accentBorder,
    Color? danger,
    Color? warn,
    Color? ok,
    Color? codeBg,
    Color? overlay,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      card: card ?? this.card,
      border: border ?? this.border,
      fg: fg ?? this.fg,
      muted: muted ?? this.muted,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      accentBorder: accentBorder ?? this.accentBorder,
      danger: danger ?? this.danger,
      warn: warn ?? this.warn,
      ok: ok ?? this.ok,
      codeBg: codeBg ?? this.codeBg,
      overlay: overlay ?? this.overlay,
    );
  }

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      card: Color.lerp(card, other.card, t)!,
      border: Color.lerp(border, other.border, t)!,
      fg: Color.lerp(fg, other.fg, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentBorder: Color.lerp(accentBorder, other.accentBorder, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      ok: Color.lerp(ok, other.ok, t)!,
      codeBg: Color.lerp(codeBg, other.codeBg, t)!,
      overlay: Color.lerp(overlay, other.overlay, t)!,
    );
  }
}

extension AppThemeX on BuildContext {
  AppColors get c => Theme.of(this).extension<AppColors>() ?? AppColors.dark;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: c.accent,
    brightness: brightness,
    surface: c.surface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    splashFactory: InkRipple.splashFactory,
    extensions: [c],
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: c.fg,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: c.fg,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: c.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: c.border, width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface2,
      isDense: true,
      hintStyle: TextStyle(color: c.muted),
      prefixIconColor: c.muted,
      suffixIconColor: c.muted,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: c.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: c.accent, width: 1.2),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: c.fg,
        foregroundColor: c.bg,
        minimumSize: const Size.fromHeight(50),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.accent),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.accent,
        side: BorderSide(color: c.accent),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      indicatorColor: c.accentSoft,
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12, color: c.fg)),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? c.accent : c.muted,
        ),
      ),
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 0.5),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.surface2,
      contentTextStyle: TextStyle(color: c.fg),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}

/// 背景光晕：深色底 + 顶部琥珀光晕 + 底部冷蓝光晕；浅色模式纯底色
class GlowBackground extends StatelessWidget {
  const GlowBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final isDark = context.isDark;
    return Container(
      decoration: BoxDecoration(
        color: c.bg,
        gradient: isDark
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color.lerp(c.bg, c.accent, 0.06)!, c.bg, c.bg],
              )
            : null,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (isDark) ...[
            Positioned(
              top: -140,
              right: -140,
              child: _glow(360, c.accent.withValues(alpha: 0.08)),
            ),
            Positioned(
              bottom: -180,
              left: -160,
              child: _glow(420, const Color(0xFF4A5A7A).withValues(alpha: 0.08)),
            ),
            Positioned(
              top: MediaQuery.sizeOf(context).height * 0.30,
              left: -200,
              child: _glow(340, c.accent.withValues(alpha: 0.04)),
            ),
          ],
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
        gradient: RadialGradient(colors: [color, Colors.transparent]),
      ),
    );
  }
}

/// 扁平进度条（对齐 Web .bar：4px 高，>80 红 / 60-80 黄 / <60 绿）
class MetricBar extends StatelessWidget {
  const MetricBar({
    super.key,
    required this.percent,
    this.height = 4,
    this.danger = false,
  });

  final double percent; // 0-100
  final double height;
  final bool danger; // 是否使用危险色（磁盘等单独用色）

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = percent.clamp(0, 100);
    Color color;
    if (danger) {
      color = p > 80 ? c.danger : (p > 60 ? c.warn : c.ok);
    } else {
      color = p > 80 ? c.danger : (p > 60 ? c.warn : c.ok);
    }
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(2),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: p / 100,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// 卡片：表面底 + 1px 边框（对齐 Web .card）
class PanelCard extends StatelessWidget {
  const PanelCard({super.key, this.title, required this.child});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: TextStyle(
                color: c.muted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.6,
              ),
            ),
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    );
  }
}

/// 小标题（大写微字距，对齐 Web .block-title / h3）
class BlockTitle extends StatelessWidget {
  const BlockTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: c.muted,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.6,
      ),
    );
  }
}

/// 状态小圆点
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.up, this.size = 8});

  final bool up;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: up ? c.ok : c.danger,
        border: up ? null : Border.all(color: c.danger, width: 1),
      ),
    );
  }
}

/// 全局提示：与 Web toast 一致（顶部居中、ok 色文字）
void showAppToast(BuildContext context, String msg, {bool ok = true}) {
  final c = context.c;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg, style: TextStyle(color: ok ? c.ok : c.fg)),
      duration: const Duration(milliseconds: 2500),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.only(top: 64, left: 24, right: 24),
      width: 320,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
  );
}
