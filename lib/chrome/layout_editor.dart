import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../util/chrome_theme.dart';

/// Holds the draft layout while the home screen is in edit mode. The chrome
/// renders from [draft], so every change shows live.
class LayoutEditController extends ChangeNotifier {
  LayoutEditController(this.original) : _draft = original;

  /// The layout in force when editing began, which Cancel and Reset return to.
  final ChromeThemeSpec original;

  ChromeThemeSpec _draft;
  LayoutBlock? _blocked;
  Object? _dragging;

  ChromeThemeSpec get draft => _draft;

  /// Why the last removal was refused, until the next change.
  LayoutBlock? get blocked => _blocked;

  bool get dirty => _draft != original;

  /// The [ChromeAction] or [ComposerPart] being dragged, if any.
  Object? get dragging => _dragging;

  void drag(Object? item) {
    if (_dragging == item) return;
    _dragging = item;
    notifyListeners();
  }

  /// Whether [place] draws [part]: it sits there, or a drag of it may land.
  bool shows(ComposerPart part, PartPlace place) =>
      _draft.placeOf(part) == place ||
      (_dragging == part && _draft.canPlacePart(part, place));

  /// Whether a field side offers a "+": the field has room, or the drag
  /// in flight is already in the field and may move across.
  bool fieldOffers() {
    final dragged = _dragging;
    return switch (dragged) {
      ChromeAction() => _draft.canPlaceField(FieldItem.action(dragged)),
      ComposerPart() => _draft.canPlaceField(FieldItem.part(dragged)),
      _ => _draft.fieldItems.length < ChromeThemeSpec.fieldCap,
    };
  }

  void placePart(ComposerPart part, PartPlace place, {int? index}) {
    _blocked = null;
    _dragging = null;
    _draft = _draft.placePart(part, place, index: index).fitted();
    notifyListeners();
  }

  /// Moves [action] to [slot] (before [index]), or removes it when [slot] is
  /// null. A removal that would strand the app is refused and explained.
  void move(ChromeAction action, LayoutSlot? slot, {int? index}) {
    _dragging = null;
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
    _draft = _draft.place(action, slot, index: index).fitted();
    notifyListeners();
  }

  void update(ChromeThemeSpec spec) {
    _blocked = null;
    _dragging = null;
    _draft = spec.fitted();
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
  LayoutSlot.fieldStart => l.layoutSlotFieldStart,
  LayoutSlot.fieldEnd => l.layoutSlotFieldEnd,
};

const _cell = 48.0;
const _grabDelay = Duration(milliseconds: 170);

String _blockReason(AppLocalizations l, LayoutBlock block) => switch (block) {
  LayoutBlock.settings => l.layoutLockedSettings,
  LayoutBlock.viewPath => l.layoutLockedViewPath,
};

/// One slot in edit mode: its buttons, then an insertion target while a
/// button is dragged.
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
      duration: const Duration(milliseconds: 160),
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
          if (controller.dragging is ChromeAction)
            _SlotEnd(controller: controller, slot: slot),
        ],
      ),
    );
  }
}

/// The insertion target that ends a slot, filled while a drag hovers it.
class _SlotEnd extends StatelessWidget {
  const _SlotEnd({required this.controller, required this.slot});

  final LayoutEditController controller;
  final LayoutSlot slot;

  @override
  Widget build(BuildContext context) {
    return DragTarget<ChromeAction>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) {
        HapticFeedback.lightImpact();
        controller.move(d.data, slot);
      },
      builder: (context, candidates, _) =>
          _InsertTarget(hot: candidates.isNotEmpty, slim: true),
    );
  }
}

/// A button-sized dashed target, filled with the primary color when hot.
class _InsertTarget extends StatelessWidget {
  const _InsertTarget({
    required this.hot,
    this.icon = Icons.add,
    this.slim = false,
    this.tall = false,
    this.onTap,
  });

  final bool hot;
  final bool slim;

  /// Fills its box instead of a button cell: the island's side column.
  final bool tall;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: tall ? double.infinity : (slim ? 28 : _cell),
      height: tall ? double.infinity : _cell,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: CustomPaint(
          painter: _DashedBox(
            color: hot ? scheme.primary : scheme.outlineVariant,
            fill: hot ? scheme.primary.withValues(alpha: 0.2) : null,
            radius: 12,
          ),
          child: Semantics(
            container: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Center(
                child: Icon(
                  icon,
                  size: 18,
                  color: hot ? scheme.primary : scheme.outlineVariant,
                ),
              ),
            ),
          ),
        ),
      ),
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
    ).deflate(0.5);
    if (fill != null) canvas.drawRRect(rrect, Paint()..color = fill!);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 7) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + 4, metric.length)),
          stroke,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox old) =>
      old.color != color || old.fill != fill || old.radius != radius;
}

/// A button as the real chrome draws it, marked editable by a faint tint and
/// a thin dashed outline. [lifted] is the dragged copy.
class _EditFace extends StatelessWidget {
  const _EditFace({
    required this.icon,
    required this.onTap,
    this.lifted = false,
    this.plain = false,
    this.tall = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool lifted;

  /// Fills its box instead of a button cell: the island's side column.
  final bool tall;

  /// Drops the dashed outline, for buttons that are not placed yet.
  final bool plain;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glyph = Icon(icon, size: 24, color: scheme.onSurface);
    return SizedBox(
      width: tall ? double.infinity : _cell,
      height: tall ? double.infinity : _cell,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: lifted
            ? Material(
                color: scheme.surfaceContainerHighest,
                elevation: 8,
                borderRadius: BorderRadius.circular(12),
                child: Center(child: glyph),
              )
            : CustomPaint(
                painter: plain
                    ? null
                    : _DashedBox(
                        color: scheme.outlineVariant,
                        fill: scheme.primary.withValues(alpha: 0.07),
                        radius: 12,
                      ),
                child: InkWell(
                  customBorder: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onTap: onTap,
                  child: Center(child: glyph),
                ),
              ),
      ),
    );
  }
}

/// Shows [items] as a menu over the button that owns [context].
Future<T?> _showMenuAt<T>(BuildContext context, List<PopupMenuEntry<T>> items) {
  final box = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return Future.value();
  final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      origin & box.size,
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}

/// The menu's Remove entry: disabled with its reason when removal is blocked.
PopupMenuItem<Object> _removeItem(BuildContext context, String? reason) {
  final theme = Theme.of(context);
  return PopupMenuItem<Object>(
    value: 'remove',
    enabled: reason == null,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(context.l10n.remove),
        if (reason != null)
          Text(
            reason,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    ),
  );
}

/// An action as an editable button: placed in a slot or unplaced in the
/// tray. It drags after a short hold, and a tap, or a hold that does not
/// move, opens the move menu.
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

  /// Where the button is placed, or null in the tray.
  final LayoutSlot? slot;

  /// Its position in [slot]. A drop on it lands before it.
  final int index;

  @override
  State<EditChip> createState() => _EditChipState();
}

class _EditChipState extends State<EditChip> {
  double _travel = 0;

  bool get _placed => widget.slot != null;

  Future<void> _openMenu() async {
    final l = context.l10n;
    final spec = widget.controller.draft;
    final block = spec.removeBlock(widget.action);
    final choice = await _showMenuAt<Object>(context, [
      for (final s in spec.slots)
        if (s != widget.slot && spec.canPlace(widget.action, s))
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
        _removeItem(context, block == null ? null : _blockReason(l, block)),
      ],
    ]);
    if (choice == null) return;
    HapticFeedback.selectionClick();
    widget.controller.move(widget.action, choice is LayoutSlot ? choice : null);
  }

  Widget _body(BuildContext context, {bool lifted = false}) {
    final face = _EditFace(
      icon: widget.action.icon,
      lifted: lifted,
      plain: !_placed,
      onTap: lifted ? null : _openMenu,
    );
    if (_placed) return face;
    return Tooltip(
      message: widget.action.label(context.l10n),
      triggerMode: TooltipTriggerMode.manual,
      child: face,
    );
  }

  @override
  Widget build(BuildContext context) {
    final chip = LongPressDraggable<ChromeAction>(
      data: widget.action,
      delay: _grabDelay,
      hapticFeedbackOnStart: false,
      dragAnchorStrategy: (draggable, context, position) =>
          const Offset(_cell / 2, _cell + 24),
      onDragStarted: () {
        _travel = 0;
        HapticFeedback.mediumImpact();
        widget.controller.drag(widget.action);
      },
      onDragUpdate: (d) => _travel += d.delta.distance,
      onDragEnd: (d) {
        widget.controller.drag(null);
        if (d.wasAccepted) return;
        // A hold that never moved asks for options instead of dragging.
        if (_travel < 8 && mounted) _openMenu();
      },
      feedback: Transform.scale(
        scale: 1.15,
        child: Material(
          type: MaterialType.transparency,
          child: _body(context, lifted: true),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: _body(context)),
      child: _body(context),
    );
    if (!_placed) return chip;
    return DragTarget<ChromeAction>(
      onWillAcceptWithDetails: (d) =>
          d.data != widget.action &&
          widget.controller.draft.canPlace(d.data, widget.slot!),
      onAcceptWithDetails: (d) {
        HapticFeedback.lightImpact();
        widget.controller.move(d.data, widget.slot, index: widget.index);
      },
      builder: (context, candidates, _) {
        final scheme = Theme.of(context).colorScheme;
        return Container(
          foregroundDecoration: candidates.isEmpty
              ? null
              : BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
          child: chip,
        );
      },
    );
  }
}

String _placeLabel(AppLocalizations l, ComposerPart part, PartPlace place) =>
    switch (place) {
      PartPlace.fieldStart => l.layoutSlotFieldStart,
      PartPlace.fieldEnd => l.layoutSlotFieldEnd,
      PartPlace.column => l.layoutSendColumn,
      PartPlace.row =>
        part == ComposerPart.emote ? l.layoutSlotRowStart : l.layoutSlotRowEnd,
    };

extension on ComposerPart {
  IconData get icon => switch (this) {
    ComposerPart.emote => Icons.emoji_emotions_outlined,
    ComposerPart.send => Icons.send,
  };

  String label(AppLocalizations l) => switch (this) {
    ComposerPart.emote => l.pickerEmotes,
    ComposerPart.send => l.send,
  };
}

/// A composer button in edit mode: its button where it sits, an insertion
/// target where a drag of it may land, nothing elsewhere.
class PartSlot extends StatelessWidget {
  const PartSlot({
    super.key,
    required this.controller,
    required this.part,
    required this.place,
  });

  final LayoutEditController controller;
  final ComposerPart part;
  final PartPlace place;

  @override
  Widget build(BuildContext context) {
    if (!controller.shows(part, place)) return const SizedBox.shrink();
    final placed = controller.draft.placeOf(part) == place;
    final target = DragTarget<ComposerPart>(
      onWillAcceptWithDetails: (d) =>
          d.data == part && controller.draft.canPlacePart(part, place),
      onAcceptWithDetails: (d) {
        HapticFeedback.lightImpact();
        controller.placePart(part, place);
      },
      builder: (context, candidates, _) => _InsertTarget(
        hot: candidates.isNotEmpty,
        icon: part.icon,
        tall: place == PartPlace.column,
      ),
    );
    // The side column runs the island's full height, so its button and its
    // target fill the column to show it.
    if (place == PartPlace.column) {
      return Padding(
        padding: const EdgeInsets.all(4),
        child: placed
            ? PartChip(
                key: ValueKey(part),
                controller: controller,
                part: part,
                tall: true,
              )
            : target,
      );
    }
    return SizedBox(
      width: _cell,
      height: 40,
      child: OverflowBox(
        minWidth: _cell,
        maxWidth: _cell,
        minHeight: _cell,
        maxHeight: _cell,
        child: Center(
          child: placed
              ? PartChip(
                  key: ValueKey(part),
                  controller: controller,
                  part: part,
                )
              : target,
        ),
      ),
    );
  }
}

/// The emote or send button as an editable button. It moves between places
/// but never leaves.
class PartChip extends StatefulWidget {
  const PartChip({
    super.key,
    required this.controller,
    required this.part,
    this.tall = false,
  });

  final LayoutEditController controller;
  final ComposerPart part;

  /// Fills the island's side column, as send does there.
  final bool tall;

  @override
  State<PartChip> createState() => _PartChipState();
}

class _PartChipState extends State<PartChip> {
  double _travel = 0;

  Future<void> _openMenu() async {
    final l = context.l10n;
    final c = widget.controller;
    final here = c.draft.placeOf(widget.part);
    final choice = await _showMenuAt<Object>(context, [
      for (final p in PartPlace.values)
        if (p != here && c.draft.canPlacePart(widget.part, p))
          PopupMenuItem<Object>(
            value: p,
            child: Text(l.layoutMoveTo(_placeLabel(l, widget.part, p))),
          ),
      const PopupMenuDivider(),
      _removeItem(context, l.layoutLockedPart),
    ]);
    if (choice is! PartPlace) return;
    HapticFeedback.selectionClick();
    c.placePart(widget.part, choice);
  }

  Widget _body({bool lifted = false}) => _EditFace(
    icon: widget.part.icon,
    lifted: lifted,
    tall: widget.tall && !lifted,
    onTap: lifted ? null : _openMenu,
  );

  @override
  Widget build(BuildContext context) {
    return LongPressDraggable<ComposerPart>(
      data: widget.part,
      delay: _grabDelay,
      hapticFeedbackOnStart: false,
      dragAnchorStrategy: (draggable, context, position) =>
          const Offset(_cell / 2, _cell + 24),
      onDragStarted: () {
        _travel = 0;
        HapticFeedback.mediumImpact();
        widget.controller.drag(widget.part);
      },
      onDragUpdate: (d) => _travel += d.delta.distance,
      onDragEnd: (d) {
        widget.controller.drag(null);
        if (d.wasAccepted) return;
        // A hold that never moved asks for options instead of dragging.
        if (_travel < 8 && mounted) _openMenu();
      },
      feedback: Transform.scale(
        scale: 1.15,
        child: Material(
          type: MaterialType.transparency,
          child: _body(lifted: true),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: _body()),
      child: _body(),
    );
  }
}

/// One side of the field row in edit mode: its buttons, then a "+" while
/// the field row has room (or a drag of a button already in it may land).
class FieldSideView extends StatelessWidget {
  const FieldSideView({
    super.key,
    required this.controller,
    required this.side,
  });

  final LayoutEditController controller;
  final LayoutSlot side;

  PartPlace get _place =>
      side == LayoutSlot.fieldStart ? PartPlace.fieldStart : PartPlace.fieldEnd;

  Future<void> _openAdd(BuildContext context) async {
    final l = context.l10n;
    final spec = controller.draft;
    final choice = await _showMenuAt<Object>(context, [
      for (final p in ComposerPart.values)
        if (!spec.inField(FieldItem.part(p)) && spec.canPlacePart(p, _place))
          PopupMenuItem<Object>(
            value: p,
            child: _MenuLabel(icon: p.icon, text: p.label(l)),
          ),
      for (final a in ChromeAction.values)
        if (!spec.inField(FieldItem.action(a)))
          PopupMenuItem<Object>(
            value: a,
            child: _MenuLabel(icon: a.icon, text: a.label(l)),
          ),
    ]);
    if (choice == null) return;
    HapticFeedback.selectionClick();
    if (choice is ChromeAction) controller.move(choice, side);
    if (choice is ComposerPart) controller.placePart(choice, _place);
  }

  @override
  Widget build(BuildContext context) {
    final items = controller.draft.itemsIn(side);
    return SizedBox(
      height: 40,
      width: (items.length + (controller.fieldOffers() ? 1 : 0)) * _cell,
      child: OverflowBox(
        minHeight: _cell,
        maxHeight: _cell,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < items.length; i++)
              if (items[i].action case final a?)
                EditChip(
                  key: ValueKey(a),
                  controller: controller,
                  action: a,
                  slot: side,
                  index: i,
                )
              else
                PartChip(
                  key: ValueKey(items[i].part),
                  controller: controller,
                  part: items[i].part!,
                ),
            if (controller.fieldOffers())
              DragTarget<Object>(
                onWillAcceptWithDetails: (d) => switch (d.data) {
                  ChromeAction a => controller.draft.canPlace(a, side),
                  ComposerPart p => controller.draft.canPlacePart(p, _place),
                  _ => false,
                },
                onAcceptWithDetails: (d) {
                  HapticFeedback.lightImpact();
                  switch (d.data) {
                    case ChromeAction a:
                      controller.move(a, side);
                    case ComposerPart p:
                      controller.placePart(p, _place);
                  }
                },
                builder: (context, candidates, _) => Builder(
                  builder: (context) => _InsertTarget(
                    hot: candidates.isNotEmpty,
                    onTap: () => unawaited(_openAdd(context)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A menu entry: an icon, then its text.
class _MenuLabel extends StatelessWidget {
  const _MenuLabel({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(text)],
  );
}

/// The edit-mode panel under the real chrome: header actions, the spare
/// buttons, the preset and header menus, and the few toggles.
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
      color: scheme.surfaceContainer,
      elevation: 6,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 8),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(context),
                  _spare(context),
                  _menus(context),
                  _toggles(context),
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
    const compact = VisualDensity.compact;
    return Row(
      children: [
        Expanded(
          child: Text(
            l.settingEditLayout,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.restart_alt),
          tooltip: l.reset,
          visualDensity: compact,
          onPressed: controller.dirty ? controller.reset : null,
        ),
        TextButton(
          onPressed: onCancel,
          style: TextButton.styleFrom(visualDensity: compact),
          child: Text(l.cancel),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: onDone,
          style: FilledButton.styleFrom(visualDensity: compact),
          child: Text(l.layoutDone),
        ),
      ],
    );
  }

  /// The unplaced actions. A dragged placed button swaps them for a target
  /// that removes it.
  Widget _spare(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final spec = controller.draft;
    final dragged = controller.dragging;
    final removing = dragged is ChromeAction && spec.slotOf(dragged) != null;
    final free = [
      for (final a in ChromeAction.values)
        if (spec.slotOf(a) == null) a,
    ];
    Widget content = const SizedBox(width: double.infinity);
    if (removing) {
      content = DragTarget<ChromeAction>(
        onWillAcceptWithDetails: (d) => spec.slotOf(d.data) != null,
        onAcceptWithDetails: (d) {
          HapticFeedback.lightImpact();
          controller.move(d.data, null);
        },
        builder: (context, candidates, _) {
          final hot = candidates.isNotEmpty;
          return Container(
            width: double.infinity,
            height: _cell,
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              color: hot
                  ? scheme.primary.withValues(alpha: 0.2)
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.delete_outline, size: 20, color: scheme.onSurface),
                const SizedBox(width: 8),
                Text(
                  l.layoutDropToRemove,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
          );
        },
      );
    } else if (free.isNotEmpty) {
      // An outlined pocket with a caption, so the spare buttons read as
      // set aside rather than as part of the chrome.
      content = Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outline, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                l.layoutUnused,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Wrap(
              children: [
                for (final a in free)
                  EditChip(
                    key: ValueKey('tray-$a'),
                    controller: controller,
                    action: a,
                  ),
              ],
            ),
          ],
        ),
      );
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 160),
      alignment: Alignment.topCenter,
      child: content,
    );
  }

  Widget _menus(BuildContext context) {
    final l = context.l10n;
    final draft = controller.draft;
    String preset(ChromeTheme t) => switch (t) {
      ChromeTheme.ermchat => l.chromeThemeErmchat,
      ChromeTheme.dankchat3 => l.chromeThemeDankchat3,
      ChromeTheme.dankchat4 => l.chromeThemeDankchat4,
    };
    String header(HeaderStyle h) => switch (h) {
      HeaderStyle.strip => l.layoutHeaderStrip,
      HeaderStyle.appBar => l.layoutHeaderAppBar,
      HeaderStyle.bubbles => l.layoutHeaderBubbles,
    };
    String composer(ComposerStyle c) => switch (c) {
      ComposerStyle.island => l.layoutComposerIsland,
      ComposerStyle.flush => l.layoutFlushIsland,
      ComposerStyle.classic => l.layoutComposerClassic,
    };
    final current = [
      for (final t in ChromeTheme.values)
        if (t.spec == draft.copyWith(name: '')) t,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          _MenuButton(
            label: current.isEmpty ? l.layoutCustom : preset(current.first),
            items: [
              for (final t in ChromeTheme.values)
                (
                  preset(t),
                  current.contains(t),
                  () {
                    HapticFeedback.selectionClick();
                    controller.update(t.spec.copyWith(name: draft.name));
                  },
                ),
            ],
          ),
          const SizedBox(width: 8),
          _MenuButton(
            label: header(draft.header),
            items: [
              for (final h in HeaderStyle.values)
                (
                  header(h),
                  draft.header == h,
                  () => controller.update(draft.withHeader(h)),
                ),
            ],
          ),
          const SizedBox(width: 8),
          _MenuButton(
            label: composer(draft.composer),
            items: [
              for (final c in ComposerStyle.values)
                (
                  composer(c),
                  draft.composer == c,
                  () => controller.update(draft.copyWith(composer: c)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toggles(BuildContext context) {
    final l = context.l10n;
    final draft = controller.draft;
    Widget toggle(String label, bool value, ValueChanged<bool> onChanged) =>
        FilterChip(
          label: Text(label),
          labelStyle: Theme.of(context).textTheme.labelMedium,
          selected: value,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onSelected: onChanged,
        );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 6,
        children: [
          toggle(
            l.layoutBusyBar,
            draft.busyBar,
            (v) => controller.update(draft.copyWith(busyBar: v)),
          ),
          if (draft.isIsland)
            toggle(
              l.layoutHideRowTyping,
              draft.compact,
              (v) => controller.update(draft.copyWith(compact: v)),
            ),
        ],
      ),
    );
  }
}

/// A compact outlined button that opens a menu of (label, selected, onTap).
class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.label, required this.items});

  final String label;
  final List<(String, bool, VoidCallback)> items;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final (text, selected, onTap) in items)
          MenuItemButton(
            leadingIcon: Icon(selected ? Icons.check : null, size: 18),
            onPressed: onTap,
            child: Text(text),
          ),
      ],
      builder: (context, menu, _) => OutlinedButton(
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [Text(label), const Icon(Icons.arrow_drop_down, size: 20)],
        ),
      ),
    );
  }
}
