import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/trio_design.dart';

/// The screen shell: panels on ground, with an optional navigation strip and
/// a pinned action bar at the foot.
class TrioScreen extends StatelessWidget {
  const TrioScreen({
    super.key,
    this.title,
    this.trailing,
    this.showBack = true,
    required this.child,
    this.action,
    this.onRefresh,
  });

  /// The mono, uppercase screen name. Null leaves the strip off entirely, for
  /// screens that carry their own header.
  final String? title;
  final Widget? trailing;
  final bool showBack;
  final Widget child;

  /// Pinned to the bottom above the home indicator, outside the scroll.
  final Widget? action;

  /// Pull-to-refresh, where the screen has something to refresh.
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final refresh = onRefresh;
    Widget body = child;
    if (refresh != null) {
      body = RefreshIndicator(
        onRefresh: refresh,
        color: colors.accent,
        backgroundColor: colors.panel,
        child: body,
      );
    }

    return Scaffold(
      backgroundColor: colors.ground,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (title != null)
              TrioNavBar(title: title!, trailing: trailing, showBack: showBack),
            Expanded(child: body),
            if (action != null) TrioActionBar(child: action!),
          ],
        ),
      ),
    );
  }
}

/// The navigation strip: back, the screen's name in mono, and whatever the
/// screen wants to keep permanently to hand on the right.
class TrioNavBar extends StatelessWidget {
  const TrioNavBar({
    super.key,
    required this.title,
    this.trailing,
    this.showBack = true,
  });

  final String title;
  final Widget? trailing;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border(bottom: BorderSide(color: colors.hairline)),
      ),
      padding: const EdgeInsets.only(left: 8, right: TrioMetrics.inset),
      child: Row(
        children: [
          if (showBack)
            Semantics(
              button: true,
              label: 'Back',
              child: InkWell(
                onTap: () => Navigator.of(context).maybePop(),
                child: SizedBox(
                  width: 40,
                  height: 44,
                  child: Icon(Icons.arrow_back, size: 22, color: colors.ink),
                ),
              ),
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: TrioType.micro(color: colors.ink, size: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// The bar the primary action sits in, held clear of the home indicator.
class TrioActionBar extends StatelessWidget {
  const TrioActionBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border(top: BorderSide(color: colors.hairline)),
      ),
      padding: EdgeInsets.fromLTRB(
        12,
        10,
        12,
        10 + MediaQuery.paddingOf(context).bottom.clamp(8.0, 34.0),
      ),
      child: child,
    );
  }
}

/// One full-bleed block of content. Panels are separated by ground, never by
/// margins of their own — [TrioPanelList] is what puts the gaps in.
class TrioPanel extends StatelessWidget {
  const TrioPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    return Container(
      width: double.infinity,
      color: color ?? colors.panel,
      padding: padding,
      child: child,
    );
  }
}

/// Panels stacked with the standard gutter of ground between them.
class TrioPanelList extends StatelessWidget {
  const TrioPanelList({
    super.key,
    required this.children,
    this.scrollable = true,
    this.padBottom = true,
  });

  final List<Widget> children;
  final bool scrollable;
  final bool padBottom;

  @override
  Widget build(BuildContext context) {
    final spaced = <Widget>[];
    for (var index = 0; index < children.length; index++) {
      if (index > 0) spaced.add(const SizedBox(height: TrioMetrics.gutter));
      spaced.add(children[index]);
    }
    if (padBottom) spaced.add(const SizedBox(height: TrioMetrics.gutter));

    if (!scrollable) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced);
    }
    return ListView(
      padding: EdgeInsets.zero,
      // Always scrollable so pull-to-refresh works even on a short screen.
      physics: const AlwaysScrollableScrollPhysics(),
      children: spaced,
    );
  }
}

/// The strip that names a group of rows.
class TrioSectionHeader extends StatelessWidget {
  const TrioSectionHeader({super.key, required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Container(
      height: TrioMetrics.headerHeight,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: TrioType.micro(color: colors.inkFaint),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A row inside a panel: a name on the left, a value on the right.
class TrioRow extends StatelessWidget {
  const TrioRow({
    super.key,
    required this.label,
    this.value,
    this.valueWidget,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.height = TrioMetrics.rowHeight,
    this.divider = true,
    this.labelColor,
    this.background,
  });

  final String label;

  /// The right-hand value, set in mono because it is nearly always a quantity.
  final String? value;
  final Widget? valueWidget;

  /// A mono caption under the label, for the state a row is in.
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double height;
  final bool divider;
  final Color? labelColor;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    final content = Container(
      height: subtitle == null ? height : null,
      constraints: subtitle == null ? null : BoxConstraints(minHeight: height + 6),
      decoration: BoxDecoration(
        color: background,
        border: divider
            ? Border(bottom: BorderSide(color: colors.hairlineSoft))
            : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset, vertical: 8),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TrioType.label(color: labelColor ?? colors.ink)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!.toUpperCase(),
                    style: TrioType.micro(
                      color: colors.inkFaint,
                      size: 10,
                      weight: FontWeight.w400,
                      tracking: 0.08,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: 12),
            Text(value!, style: TrioType.numeral(size: 12.5, color: colors.inkMuted)),
          ],
          if (valueWidget != null) ...[const SizedBox(width: 12), valueWidget!],
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: content),
    );
  }
}

/// The chevron that says a row opens something.
class TrioChevron extends StatelessWidget {
  const TrioChevron({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    return Icon(Icons.chevron_right, size: 20, color: color ?? colors.inkFaint);
  }
}

/// The bordered segmented control: the chosen segment is filled with ink, the
/// rest are quiet. No rounding, no sliding thumb.
class TrioSegmented<T> extends StatelessWidget {
  const TrioSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.height = 40,
    this.bordered = true,
    this.labelSize = 11,
  });

  final List<(T value, String label)> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final double height;

  /// Bordered for a control inside a panel; borderless for the chart's
  /// full-bleed span picker, which is ruled by the panel edge instead.
  final bool bordered;
  final double labelSize;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Container(
      height: height,
      decoration: BoxDecoration(
        border: bordered
            ? Border.all(color: colors.rule)
            : Border(bottom: BorderSide(color: colors.hairline)),
      ),
      child: Row(
        children: [
          for (final (value, label) in segments)
            Expanded(
              child: Semantics(
                button: true,
                selected: value == selected,
                label: label,
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(value),
                  child: Container(
                    alignment: Alignment.center,
                    color: value == selected ? colors.ink : Colors.transparent,
                    child: Text(
                      label.toUpperCase(),
                      style: TrioType.micro(
                        color: value == selected ? colors.panel : colors.inkMuted,
                        size: labelSize,
                        weight: value == selected ? FontWeight.w600 : FontWeight.w500,
                        tracking: 0.11,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The square switch. Filled and pushed right when on; outlined and small when
/// off, so the two states differ in shape as well as colour.
class TrioToggle extends StatelessWidget {
  const TrioToggle({super.key, required this.value, required this.onChanged, this.label});

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final enabled = onChanged != null;

    return Semantics(
      toggled: value,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Container(
            width: 46,
            height: 28,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            padding: EdgeInsets.symmetric(horizontal: value ? 3 : 4),
            decoration: BoxDecoration(
              color: value ? colors.accent : colors.ground,
              border: value ? null : Border.all(color: colors.rule, width: 1.5),
            ),
            child: Container(
              width: value ? 22 : 16,
              height: value ? 22 : 16,
              color: value ? colors.onAccent : colors.inkFaint,
            ),
          ),
        ),
      ),
    );
  }
}

/// A bordered −/+ pair that steps a value, with the step size written in it.
class TrioStepper extends StatelessWidget {
  const TrioStepper({
    super.key,
    required this.step,
    required this.onDecrement,
    required this.onIncrement,
    this.height = 56,
    this.semanticUnit = '',
  });

  /// How much one press moves the value, as it should read on the buttons.
  final String step;
  final VoidCallback? onDecrement;
  final VoidCallback? onIncrement;
  final double height;

  /// What a screen reader should call the thing being stepped.
  final String semanticUnit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StepButton(
            icon: Icons.remove,
            step: step,
            iconFirst: true,
            height: height,
            onPressed: onDecrement,
            semanticLabel: 'Decrease by $step $semanticUnit',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StepButton(
            icon: Icons.add,
            step: step,
            iconFirst: false,
            height: height,
            onPressed: onIncrement,
            semanticLabel: 'Increase by $step $semanticUnit',
          ),
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.step,
    required this.iconFirst,
    required this.height,
    required this.onPressed,
    required this.semanticLabel,
  });

  final IconData icon;
  final String step;
  final bool iconFirst;
  final double height;
  final VoidCallback? onPressed;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final enabled = onPressed != null;

    final glyph = Icon(icon, size: 20, color: enabled ? colors.ink : colors.inkFaint);
    final caption = Text(step, style: TrioType.micro(
      color: colors.inkFaint,
      size: 11,
      weight: FontWeight.w500,
      tracking: 0.08,
    ));

    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled
            ? () {
                HapticFeedback.selectionClick();
                onPressed!();
              }
            : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            height: height,
            decoration: BoxDecoration(border: Border.all(color: colors.rule)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: iconFirst
                  ? [glyph, const SizedBox(width: 8), caption]
                  : [caption, const SizedBox(width: 8), glyph],
            ),
          ),
        ),
      ),
    );
  }
}

/// A quick-set chip: a bordered box that jumps the value straight to a number.
class TrioQuickChip extends StatelessWidget {
  const TrioQuickChip({super.key, required this.label, required this.onTap, this.height = 40});

  final String label;
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(border: Border.all(color: colors.hairline)),
          child: Text(
            label,
            style: TrioType.numeral(size: 12, color: colors.inkMuted),
          ),
        ),
      ),
    );
  }
}

/// An ordinary filled action — one tap, for things that do not send a command.
class TrioButton extends StatelessWidget {
  const TrioButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.background,
    this.foreground,
    this.outlined = false,
    this.height = TrioMetrics.actionHeight,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? background;
  final Color? foreground;
  final bool outlined;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final enabled = onPressed != null;
    final fill = background ?? colors.accent;
    final ink = foreground ?? (outlined ? fill : colors.onAccent);

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: outlined ? Colors.transparent : fill,
              border: outlined ? Border.all(color: fill, width: 1.5) : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 19, color: ink),
                  const SizedBox(width: 9),
                ],
                Flexible(
                  child: Text(
                    label.toUpperCase(),
                    overflow: TextOverflow.ellipsis,
                    style: TrioType.micro(
                      color: ink,
                      size: 12,
                      tracking: 0.16,
                    ),
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

/// The way every command leaves this app: press and hold while a fill crosses
/// the button, and let go early to abandon it.
///
/// Not decoration. A follower is often reaching for this phone one-handed, in
/// a pocket, in the dark, and a bolus is not something a brush against the
/// screen should be able to send. The hold is also what makes the button its
/// own confirmation, so an ordinary command needs one deliberate gesture
/// rather than a tap and then a dialog.
class TrioHoldButton extends StatefulWidget {
  const TrioHoldButton({
    super.key,
    required this.label,
    required this.onCompleted,
    this.hold = const Duration(milliseconds: 700),
    this.background,
    this.foreground,
    this.icon,
    this.height = TrioMetrics.actionHeight,
    this.enabled = true,
  });

  final String label;

  /// Run once the hold completes. Nothing happens if the finger lifts first.
  final VoidCallback onCompleted;

  /// How long the fill takes to cross. Longer for anything that stops insulin.
  final Duration hold;
  final Color? background;
  final Color? foreground;
  final IconData? icon;
  final double height;
  final bool enabled;

  @override
  State<TrioHoldButton> createState() => _TrioHoldButtonState();
}

class _TrioHoldButtonState extends State<TrioHoldButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.hold,
  )..addStatusListener(_onStatus);

  @override
  void didUpdateWidget(covariant TrioHoldButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hold != widget.hold) _controller.duration = widget.hold;
    if (!widget.enabled) _controller.stop();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // A distinct, heavier tick than the one the hold starts with: this is the
    // moment the command is actually on its way.
    HapticFeedback.heavyImpact();
    _controller.value = 0;
    widget.onCompleted();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    if (!widget.enabled) return;
    HapticFeedback.selectionClick();
    _controller.forward(from: 0);
  }

  void _abandon() {
    if (!_controller.isAnimating) return;
    // Springs back rather than snapping, so letting go reads as "not sent"
    // instead of as a glitch.
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final fill = widget.background ?? colors.accent;
    final ink = widget.foreground ?? colors.onAccent;

    return Semantics(
      button: true,
      enabled: widget.enabled,
      // Screen reader users get a plain activation: the hold is a guard
      // against an accidental brush, and a deliberate double tap is not one.
      onTap: widget.enabled ? widget.onCompleted : null,
      label: '${widget.label}. Press and hold to send.',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _start(),
        onTapUp: (_) => _abandon(),
        onTapCancel: _abandon,
        child: Opacity(
          opacity: widget.enabled ? 1 : 0.45,
          child: SizedBox(
            height: widget.height,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: fill),
                  // The fill crossing the button is the whole feedback: it says
                  // how much longer, and it is visible past a thumb.
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: _controller.value,
                    child: ColoredBox(color: ink.withValues(alpha: 0.16)),
                  ),
                  Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.icon != null) ...[
                          Icon(widget.icon, size: 19, color: ink),
                          const SizedBox(width: 9),
                        ],
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              widget.label.toUpperCase(),
                              overflow: TextOverflow.ellipsis,
                              style: TrioType.micro(color: ink, size: 12, tracking: 0.18),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The short caption under a primary action, for what happens after the hold.
class TrioActionNote extends StatelessWidget {
  const TrioActionNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text.toUpperCase(),
        textAlign: TextAlign.center,
        style: TrioType.micro(
          color: colors.inkFaint,
          size: 9.5,
          weight: FontWeight.w500,
          tracking: 0.12,
        ),
      ),
    );
  }
}

/// A paragraph of explanation inside a panel.
class TrioNote extends StatelessWidget {
  const TrioNote({super.key, required this.text, this.padding});

  final String text;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    return Padding(
      padding: padding ??
          const EdgeInsets.fromLTRB(
            TrioMetrics.inset,
            14,
            TrioMetrics.inset,
            16,
          ),
      child: Text(text, style: TrioType.body(color: colors.inkMuted, size: 12.5)),
    );
  }
}

/// The 3-point accent rule that marks a row as belonging to something — a
/// treatment's kind, an active adjustment, a chosen preset.
class TrioTick extends StatelessWidget {
  const TrioTick({super.key, required this.color, this.height = 16, this.width = 3});

  final Color color;
  final double height;
  final double width;

  @override
  Widget build(BuildContext context) =>
      Container(width: width, height: height, color: color);
}
