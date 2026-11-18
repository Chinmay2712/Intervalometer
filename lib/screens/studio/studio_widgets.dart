import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const kStudioAccent = Color(0xFF8DB8FF);
const kStudioViolet = Color(0xFFB59CFF);
const kStudioBg = Color(0xFF05060A);
const kStudioGradient = LinearGradient(colors: [Color(0xFF8DB8FF), Color(0xFFB59CFF)]);

/// Deep night-sky backdrop: gradient, a faint Milky Way band and stars.
class StarfieldBackground extends StatelessWidget {
  const StarfieldBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const RepaintBoundary(child: CustomPaint(painter: _StarfieldPainter(), child: SizedBox.expand()));
  }
}

class _StarfieldPainter extends CustomPainter {
  const _StarfieldPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF070A14), Color(0xFF0B1124), Color(0xFF120C22), kStudioBg],
          stops: [0, 0.4, 0.75, 1],
        ).createShader(rect),
    );
    // Milky Way band.
    canvas.save();
    canvas.translate(size.width * 0.5, size.height * 0.42);
    canvas.rotate(-0.55);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: size.longestSide * 1.4, height: size.shortestSide * 0.45),
      Paint()
        ..shader = RadialGradient(colors: [
          const Color(0xFF6E7BB8).withValues(alpha: 0.16),
          const Color(0xFF6E7BB8).withValues(alpha: 0),
        ]).createShader(Rect.fromCenter(center: Offset.zero, width: size.longestSide, height: size.shortestSide * 0.45))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30),
    );
    canvas.restore();
    // Stars (fixed seed so they never jump between frames).
    final rnd = Random(7);
    final star = Paint();
    for (var i = 0; i < 160; i++) {
      final p = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
      final r = rnd.nextDouble() < 0.08 ? 1.3 : 0.6 + rnd.nextDouble() * 0.4;
      star.color = Colors.white.withValues(alpha: 0.15 + rnd.nextDouble() * 0.45);
      canvas.drawCircle(p, r, star);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Frosted-glass floating surface.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 22,
    this.padding = EdgeInsets.zero,
    this.opacity = 0.55,
    this.highlight = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double opacity;

  /// Brighter border (for the focused element).
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF1C2130).withValues(alpha: opacity),
                const Color(0xFF0E1018).withValues(alpha: opacity + 0.1),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: highlight ? 0.18 : 0.08)),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Round glass icon button.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({super.key, required this.icon, required this.onPressed, this.tooltip, this.size = 44});

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final button = Glass(
      radius: size / 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.45, color: onPressed == null ? Colors.white30 : Colors.white),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// One option of the side capsule; [panel] is shown when it expands.
class SideItem {
  const SideItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.panel,
    this.active = false,
  });

  final String id;
  final IconData icon;
  final String label;
  final WidgetBuilder panel;

  /// Shows a dot: the option is on / the edit is in use.
  final bool active;
}

/// Lets controls inside an expanded capsule close it after a choice.
class CapsuleScope extends InheritedWidget {
  const CapsuleScope({super.key, required this.collapse, required super.child});

  final VoidCallback collapse;

  /// Closes the capsule shortly after a choice, so the change is visible first.
  static void collapseSoon(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<CapsuleScope>();
    if (scope != null) Timer(const Duration(milliseconds: 380), scope.collapse);
  }

  @override
  bool updateShouldNotify(CapsuleScope oldWidget) => false;
}

/// The left capsule of option icons. Tapping one makes the capsule itself
/// grow sideways to show that option's controls, and shrink back after.
class ExpandingCapsule extends StatelessWidget {
  const ExpandingCapsule({
    super.key,
    required this.items,
    required this.openId,
    required this.onTap,
    required this.onCollapse,
    required this.panelWidth,
    required this.maxHeight,
  });

  final List<SideItem> items;
  final String? openId;
  final ValueChanged<String> onTap;
  final VoidCallback onCollapse;
  final double panelWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    SideItem? open;
    for (final i in items) {
      if (i.id == openId) open = i;
    }
    return CapsuleScope(
      collapse: onCollapse,
      child: Glass(
        radius: 28,
        opacity: open == null ? 0.55 : 0.82,
        highlight: open != null,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 340),
          curve: Curves.easeOutCubic,
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [for (final item in items) _icon(item)],
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  // Grows sideways only; the height follows the content.
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: ClipRect(
                      child: AnimatedBuilder(
                        animation: anim,
                        builder: (_, child) => Align(
                          alignment: Alignment.topLeft,
                          widthFactor: anim.value,
                          heightFactor: 1,
                          child: child,
                        ),
                        child: child,
                      ),
                    ),
                  ),
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.topLeft,
                    children: [...previous, ?current],
                  ),
                  child: open == null
                      ? const SizedBox(key: ValueKey('closed'), height: 0)
                      : SizedBox(
                          key: ValueKey(open.id),
                          width: panelWidth,
                          child: _Panel(item: open, onClose: onCollapse),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _icon(SideItem item) {
    final selected = openId == item.id;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Tooltip(
        message: item.label,
        preferBelow: false,
        child: GestureDetector(
          onTap: () => onTap(item.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: selected
                  ? LinearGradient(colors: [
                      kStudioAccent.withValues(alpha: 0.35),
                      kStudioViolet.withValues(alpha: 0.25),
                    ])
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(item.icon, size: 22, color: selected ? Colors.white : Colors.white70),
                if (item.active)
                  Positioned(
                    right: 7,
                    top: 7,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(shape: BoxShape.circle, gradient: kStudioGradient),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.item, required this.onClose});
  final SideItem item;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 2, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.2)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Close',
                icon: const Icon(Icons.keyboard_double_arrow_left_rounded, size: 20),
                onPressed: onClose,
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(4, 0, 14, 14),
            child: item.panel(context),
          ),
        ),
      ],
    );
  }
}

class ToolBarItem {
  const ToolBarItem(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// Floating tool switcher with a sliding highlight.
class ToolSwitcher extends StatelessWidget {
  const ToolSwitcher({super.key, required this.items, required this.selected, required this.onSelect});

  final List<ToolBarItem> items;
  final int selected;
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    final enabled = onSelect != null;
    return Glass(
      radius: 32,
      padding: const EdgeInsets.all(6),
      child: SizedBox(
        height: 56,
        child: LayoutBuilder(builder: (context, constraints) {
          final w = constraints.maxWidth / items.length;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                left: w * selected,
                top: 0,
                bottom: 0,
                width: w,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    gradient: LinearGradient(colors: [
                      kStudioAccent.withValues(alpha: enabled ? 0.30 : 0.12),
                      kStudioViolet.withValues(alpha: enabled ? 0.22 : 0.08),
                    ]),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: enabled ? () => onSelect!(i) : null,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(items[i].icon,
                                size: 22,
                                color: !enabled ? Colors.white24 : (i == selected ? Colors.white : Colors.white54)),
                            const SizedBox(height: 3),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                items[i].label,
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 11,
                                  letterSpacing: 0.3,
                                  fontWeight: i == selected ? FontWeight.w600 : FontWeight.w400,
                                  color: !enabled ? Colors.white24 : (i == selected ? Colors.white : Colors.white54),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        }),
      ),
    );
  }
}

/// Labelled pill for the main action (Export / Stop / Save).
class ActionPill extends StatelessWidget {
  const ActionPill({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.danger = false,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final fg = enabled ? (danger ? Colors.white : const Color(0xFF0B0E18)) : Colors.white38;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled || busy ? 1 : 0.7,
      child: GestureDetector(
        onTap: onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: enabled && !danger ? kStudioGradient : null,
            color: danger ? const Color(0xFFE5484D) : (enabled ? null : Colors.white.withValues(alpha: 0.08)),
            border: enabled ? null : Border.all(color: Colors.white12),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: (danger ? const Color(0xFFE5484D) : kStudioAccent).withValues(alpha: 0.4),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
              else
                Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 14, letterSpacing: 0.3)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Labelled slider; double-tap the label to reset.
class EditSlider extends StatelessWidget {
  const EditSlider({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = -1,
    this.max = 1,
    this.neutral = 0,
    this.format,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final double neutral;
  final String Function(double)? format;

  /// interactive = true while dragging, false when released.
  final void Function(double value, bool interactive) onChanged;

  @override
  Widget build(BuildContext context) {
    final text = format?.call(value) ??
        (min < 0 ? '${value >= 0 ? '+' : ''}${(value * 100).round()}' : '${(value * 100).round()}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onDoubleTap: () => onChanged(neutral, false),
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(label,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                ),
                Text(text,
                    style: TextStyle(
                        fontSize: 12,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                        color: value == neutral ? Colors.white38 : kStudioAccent)),
              ],
            ),
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: kStudioAccent,
            thumbColor: Colors.white,
            inactiveTrackColor: Colors.white12,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: SizedBox(
            height: 30,
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: (v) => onChanged(v, true),
              onChangeEnd: (v) => onChanged(v, false),
            ),
          ),
        ),
      ],
    );
  }
}

/// Rounded option chip. By default a tap also closes the capsule.
class OptionChip extends StatelessWidget {
  const OptionChip({super.key, required this.label, required this.selected, required this.onTap, this.collapse = true});

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool collapse;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap == null
          ? null
          : () {
              onTap!();
              if (collapse) CapsuleScope.collapseSoon(context);
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: selected
              ? LinearGradient(colors: [kStudioAccent.withValues(alpha: 0.32), kStudioViolet.withValues(alpha: 0.24)])
              : null,
          color: selected ? null : Colors.white.withValues(alpha: 0.06),
          border: Border.all(color: selected ? kStudioAccent.withValues(alpha: 0.7) : Colors.white12),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                color: onTap == null ? Colors.white30 : (selected ? Colors.white : Colors.white70),
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
      ),
    );
  }
}

/// Switch row. Toggling also closes the capsule.
class OptionSwitch extends StatelessWidget {
  const OptionSwitch({super.key, required this.title, required this.subtitle, required this.value, this.onChanged, this.collapse = true});

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool collapse;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.white54)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            activeThumbColor: Colors.white,
            activeTrackColor: kStudioAccent,
            onChanged: onChanged == null
                ? null
                : (v) {
                    onChanged!(v);
                    if (collapse) CapsuleScope.collapseSoon(context);
                  },
          ),
        ],
      ),
    );
  }
}
