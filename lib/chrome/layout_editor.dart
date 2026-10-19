import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../util/chrome_theme.dart';

/// Holds the draft layout while the home screen is in edit mode. The chrome
/// renders from [draft], so every change shows live.
class LayoutEditController extends ChangeNotifier {
  LayoutEditController(this.original) : _draft = original;

  /// The layout in force when editing began; Cancel and Reset return to it.
  final ChromeThemeSpec original;

  ChromeThemeSpec _draft;
  LayoutBlock? _blocked;

  ChromeThemeSpec get draft => _draft;

  /// Why the last removal was refused, until the next change.
  LayoutBlock? get blocked => _blocked;

  bool get dirty => _draft != original;

  /// Moves [action] to [slot] (before [index]), or removes it when [slot] is
  /// null. A removal that would strand the app is refused and explained.
  void move(ChromeAction action, LayoutSlot? slot, {int? index}) {
    if (slot == null) {
      final block = _draft.removeBlock(action);
      if (block != null) {
        HapticFeedback.heavyImpact();
        _blocked = block;
        notifyListeners();
        return;
      }
    }
    _blocked = null;
    _draft = _draft.place(action, slot, index: index);
    notifyListeners();
  }

  void update(ChromeThemeSpec spec) {
    _blocked = null;
    _draft = spec;
    notifyListeners();
  }

  void reset() => update(original);
}

extension on ChromeAction {
  IconData get icon => switch (this) {
    ChromeAction.join => Icons.add,
    ChromeAction.mentions => Icons.notifications_active,
    ChromeAction.threads => Icons.forum_outlined,
    ChromeAction.settings => Icons.settings,
    ChromeAction.overflow => Icons.more_vert,
    ChromeAction.viewMenu => Icons.expand_more,
  };

  String label(AppLocalizations l) => switch (this) {
    ChromeAction.join => l.joinChannel,
    ChromeAction.mentions => l.sectionMentions,
    ChromeAction.threads => l.threads,
    ChromeAction.settings => l.settingsTitle,
    ChromeAction.overflow => l.layoutActionOverflow,
    ChromeAction.viewMenu => l.layoutActionView,
  };
}

String _slotLabel(AppLocalizations l, LayoutSlot slot) => switch (slot) {
  LayoutSlot.strip => l.layoutSlotStrip,
  LayoutSlot.appBar => l.layoutSlotAppBar,
  LayoutSlot.rowStart => l.layoutSlotRowStart,
  LayoutSlot.rowEnd => l.layoutSlotRowEnd,
};

const _chipSize = 44.0;
const _grabDelay = Duration(milliseconds: 170);

/// One slot in edit mode: its chips, then a dashed target that appends.
class LayoutSlotView extends StatelessWidget {
  const LayoutSlotView({
    super.key,
    required this.controller,
    required this.slot,
  });

  final LayoutEditController controller;
  final LayoutSlot slot;

  @override
  Widget build(BuildContext context) {
    final actions = controller.draft.actionsIn(slot);
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: AlignmentDirectional.centerStart,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < actions.length; i++)
            EditChip(
              key: ValueKey(actions[i]),
              controller: controller,
              action: actions[i],
              slot: slot,
              index: i,
            ),
          _SlotEnd(controller: controller, slot: slot),
        ],
      ),
    );
  }
}

/// The dashed target that ends a slot, lit while a drag hovers it.
class _SlotEnd extends StatelessWidget {
  const _SlotEnd({required this.controller, required this.slot});

  final LayoutEditController controller;
  final LayoutSlot slot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<ChromeAction>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) {
        HapticFeedback.lightImpact();
        controller.move(d.data, slot);
      },
      builder: (context, candidates, _) {
        final hot = candidates.isNotEmpty;
        return Tooltip(
          message: _slotLabel(context.l10n, slot),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.all(2),
            width: hot ? _chipSize : 36,
            height: hot ? _chipSize : 36,
            child: CustomPaint(
              painter: _DashedBox(
                color: hot ? scheme.primary : scheme.outline,
                fill: hot ? scheme.primary.withValues(alpha: 0.18) : null,
                radius: 12,
              ),
              child: Icon(
                Icons.add,
                size: 18,
                color: hot ? scheme.primary : scheme.outline,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DashedBox extends CustomPainter {
  const _DashedBox({required this.color, required this.radius, this.fill});

  final Color color;
  final Color? fill;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    ).deflate(1);
    if (fill != null) canvas.drawRRect(rrect, Paint()..color = fill!);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 9) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + 5, metric.length)),
          stroke,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox old) =>
      old.color != color || old.fill != fill || old.radius != radius;
}

/// An action as an editable chip: placed in a slot (small, wiggling, with a
/// remove badge) or unplaced in the tray (large). It drags after a short
/// hold, and a hold that does not move, or a tap, opens the move menu.
class EditChip extends StatefulWidget {
  const EditChip({
    super.key,
    required this.controller,
    required this.action,
    this.slot,
    this.index = 0,
  });

  final LayoutEditController controller;
  final ChromeAction action;

  /// Where the chip is placed; null in the tray.
  final LayoutSlot? slot;

  /// Its position in [slot]; a drop on it lands before it.
  final int index;

  @override
  State<EditChip> createState() => _EditChipState();
}

class _EditChipState extends State<EditChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wiggle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    value: (widget.action.index % 3) / 3,
  );
  double _travel = 0;

  bool get _placed => widget.slot != null;

  @override
  void initState() {
    super.initState();
    if (_placed) _wiggle.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(EditChip old) {
    super.didUpdateWidget(old);
    if (_placed && !_wiggle.isAnimating) _wiggle.repeat(reverse: true);
    if (!_placed) _wiggle.stop();
  }

  @override
  void dispose() {
    _wiggle.dispose();
    super.dispose();
  }

  Future<void> _openMenu() async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final l = context.l10n;
    final spec = widget.controller.draft;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final position = RelativeRect.fromRect(
      origin & box.size,
      Offset.zero & overlay.size,
    );
    final locked = spec.removeBlock(widget.action) != null;
    final choice = await showMenu<Object>(
      context: context,
      position: position,
      items: [
        for (final s in spec.slots)
          if (s != widget.slot)
            PopupMenuItem<Object>(
              value: s,
              child: Text(
                _placed
                    ? l.layoutMoveTo(_slotLabel(l, s))
                    : l.layoutAddTo(_slotLabel(l, s)),
              ),
            ),
        if (_placed) ...[
          const PopupMenuDivider(),
          PopupMenuItem<Object>(
            value: 'remove',
            child: Row(
              children: [
                Expanded(child: Text(l.remove)),
                if (locked) const Icon(Icons.lock_outline, size: 18),
              ],
            ),
          ),
        ],
      ],
    );
    if (choice == null) return;
    HapticFeedback.selectionClick();
    widget.controller.move(widget.action, choice is LayoutSlot ? choice : null);
  }

  Widget _body(BuildContext context, {bool lifted = false}) {
    final scheme = Theme.of(context).colorScheme;
    final l = context.l10n;
    final icon = Icon(widget.action.icon, size: 22);
    if (!_placed) {
      return Material(
        color: scheme.secondaryContainer,
        elevation: lifted ? 8 : 0,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: lifted ? null : _openMenu,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(width: 8),
                Text(
                  widget.action.label(l),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
          ),
        ),
      );
    }
    final locked = widget.controller.draft.removeBlock(widget.action) != null;
    return SizedBox.square(
      dimension: _chipSize,
      child: Stack(
        children: [
          Positioned.fill(
            child: Material(
              color: scheme.primaryContainer,
              elevation: lifted ? 8 : 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: scheme.primary, width: 1.5),
              ),
              child: InkWell(
                customBorder: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onTap: lifted ? null : _openMenu,
                child: Center(child: icon),
              ),
            ),
          ),
          if (!lifted)
            Positioned(
              top: 1,
              right: 1,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.controller.move(widget.action, null),
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: locked ? scheme.tertiary : scheme.error,
                  ),
                  child: Icon(
                    locked ? Icons.lock : Icons.close,
                    size: 12,
                    color: locked ? scheme.onTertiary : scheme.onError,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    Widget body = _body(context);
    if (_placed && !still) {
      body = AnimatedBuilder(
        animation: _wiggle,
        builder: (_, child) =>
            Transform.rotate(angle: (_wiggle.value - 0.5) * 0.04, child: child),
        child: body,
      );
    }
    final feedbackSize = _placed ? _chipSize : 56.0;
    Widget chip = LongPressDraggable<ChromeAction>(
      data: widget.action,
      delay: _grabDelay,
      hapticFeedbackOnStart: false,
      dragAnchorStrategy: (draggable, context, position) =>
          Offset(feedbackSize / 2, feedbackSize + 24),
      onDragStarted: () {
        _travel = 0;
        HapticFeedback.mediumImpact();
      },
      onDragUpdate: (d) => _travel += d.delta.distance,
      onDragEnd: (d) {
        if (d.wasAccepted) return;
        // A hold that never moved asks for options instead of dragging.
        if (_travel < 8 && mounted) _openMenu();
      },
      feedback: Transform.scale(
        scale: 1.18,
        child: Material(
          type: MaterialType.transparency,
          child: _body(context, lifted: true),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: body),
      child: body,
    );
    chip = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.6, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
      child: chip,
    );
    if (!_placed) return chip;
    return DragTarget<ChromeAction>(
      onWillAcceptWithDetails: (d) => d.data != widget.action,
      onAcceptWithDetails: (d) {
        HapticFeedback.lightImpact();
        widget.controller.move(d.data, widget.slot, index: widget.index);
      },
      builder: (context, candidates, _) {
        final scheme = Theme.of(context).colorScheme;
        return Container(
          margin: const EdgeInsets.all(2),
          foregroundDecoration: candidates.isEmpty
              ? null
              : BoxDecoration(
                  border: BorderDirectional(
                    start: BorderSide(color: scheme.primary, width: 3),
                  ),
                ),
          child: chip,
        );
      },
    );
  }
}

/// The edit-mode panel under the real chrome: unplaced actions, presets and
/// the few non-action options, with Reset, Cancel and Done.
class LayoutEditTray extends StatelessWidget {
  const LayoutEditTray({
    super.key,
    required this.controller,
    required this.onDone,
    required this.onCancel,
  });

  final LayoutEditController controller;
  final VoidCallback onDone;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.5,
          ),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context),
                  _notice(context),
                  const SizedBox(height: 8),
                  _unplaced(context),
                  const SizedBox(height: 12),
                  _presets(context),
                  const SizedBox(height: 12),
                  _options(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final l = context.l10n;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.settingEditLayout, style: text.titleMedium),
              Text(
                l.layoutEditHint,
                style: text.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        TextButton(onPressed: onCancel, child: Text(l.cancel)),
        const SizedBox(width: 4),
        FilledButton(onPressed: onDone, child: Text(l.layoutDone)),
      ],
    );
  }

  Widget _notice(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final blocked = controller.blocked;
    return AnimatedSize(
      duration: const Duration(milliseconds: 160),
      alignment: Alignment.topCenter,
      child: blocked == null
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 18,
                    color: scheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      switch (blocked) {
                        LayoutBlock.settings => l.layoutLockedSettings,
                        LayoutBlock.viewPath => l.layoutLockedViewPath,
                      },
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _label(BuildContext context, String text, {Widget? trailing}) => Row(
    children: [
      Expanded(
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      ?trailing,
    ],
  );

  Widget _unplaced(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final spec = controller.draft;
    final free = [
      for (final a in ChromeAction.values)
        if (spec.slotOf(a) == null) a,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(context, l.layoutNotPlaced),
        const SizedBox(height: 6),
        DragTarget<ChromeAction>(
          onWillAcceptWithDetails: (d) => spec.slotOf(d.data) != null,
          onAcceptWithDetails: (d) {
            HapticFeedback.lightImpact();
            controller.move(d.data, null);
          },
          builder: (context, candidates, _) {
            final hot = candidates.isNotEmpty;
            return CustomPaint(
              painter: _DashedBox(
                color: hot ? scheme.primary : scheme.outlineVariant,
                fill: hot ? scheme.primary.withValues(alpha: 0.12) : null,
                radius: 16,
              ),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(minHeight: 72),
                padding: const EdgeInsets.all(10),
                alignment: AlignmentDirectional.centerStart,
                child: hot
                    ? Center(
                        child: Text(
                          l.layoutDropToRemove,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: scheme.primary),
                        ),
                      )
                    : Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final a in free)
                            EditChip(
                              key: ValueKey('tray-$a'),
                              controller: controller,
                              action: a,
                            ),
                        ],
                      ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _presets(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final draft = controller.draft;
    (String, String) words(ChromeTheme t) => switch (t) {
      ChromeTheme.ermchat => (l.chromeThemeErmchat, l.chromeThemeErmchatHint),
      ChromeTheme.dankchat3 => (
        l.chromeThemeDankchat3,
        l.chromeThemeDankchat3Hint,
      ),
      ChromeTheme.dankchat4 => (
        l.chromeThemeDankchat4,
        l.chromeThemeDankchat4Hint,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(
          context,
          l.layoutStartFrom,
          trailing: TextButton(
            onPressed: controller.dirty ? controller.reset : null,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(l.reset),
          ),
        ),
        SizedBox(
          height: 78,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final t in ChromeTheme.values)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: SizedBox(
                    width: 150,
                    child: Card.outlined(
                      margin: EdgeInsets.zero,
                      color: t.spec == draft.copyWith(name: '')
                          ? scheme.primaryContainer
                          : null,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          controller.update(t.spec.copyWith(name: draft.name));
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(words(t).$1, style: text.labelLarge),
                              const SizedBox(height: 2),
                              Text(
                                words(t).$2,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _options(BuildContext context) {
    final l = context.l10n;
    final draft = controller.draft;
    final text = Theme.of(context).textTheme;
    final style = ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: WidgetStatePropertyAll(text.labelMedium),
    );
    Widget row(String label, Widget control) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 64, child: Text(label, style: text.labelLarge)),
          Expanded(child: control),
        ],
      ),
    );
    return Column(
      children: [
        row(
          l.layoutHeader,
          SegmentedButton<HeaderStyle>(
            style: style,
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: HeaderStyle.strip,
                label: Text(l.layoutHeaderStrip),
              ),
              ButtonSegment(
                value: HeaderStyle.appBar,
                label: Text(l.layoutHeaderAppBar),
              ),
              ButtonSegment(
                value: HeaderStyle.bubbles,
                label: Text(l.layoutHeaderBubbles),
              ),
            ],
            selected: {draft.header},
            onSelectionChanged: (s) =>
                controller.update(draft.withHeader(s.first)),
          ),
        ),
        row(
          l.layoutSend,
          SegmentedButton<SendPlace>(
            style: style,
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: SendPlace.field,
                label: Text(l.layoutSendField),
              ),
              ButtonSegment(
                value: SendPlace.column,
                label: Text(l.layoutSendColumn),
              ),
              ButtonSegment(value: SendPlace.row, label: Text(l.layoutSendRow)),
            ],
            selected: {draft.send},
            onSelectionChanged: (s) =>
                controller.update(draft.copyWith(send: s.first)),
          ),
        ),
        Row(
          children: [
            FilterChip(
              label: Text(l.layoutFlushIsland),
              selected: draft.islandFlush,
              onSelected: (v) =>
                  controller.update(draft.copyWith(islandFlush: v)),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: Text(l.layoutBusyBar),
              selected: draft.busyBar,
              onSelected: (v) => controller.update(draft.copyWith(busyBar: v)),
            ),
          ],
        ),
      ],
    );
  }
}
