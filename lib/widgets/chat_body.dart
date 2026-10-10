import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../composer/composer_bar.dart';
import '../util/insets.dart';
import '../util/prefs.dart';
import 'glass_chrome.dart';

/// Builds the chat content above the composer. [maxHeight] and [keyboardH]
/// feed keyboard decisions only: while the keyboard is up they describe the
/// settled room above the composer, whether it docks or floats, so the
/// decisions never flip mid-animation.
/// [composerH] is the composer's content height, without the safe area.
typedef ChatBodyBuilder =
    Widget Function(
      BuildContext context, {
      required bool hideChromeForKeyboard,
      required double maxWidth,
      required double maxHeight,
      required double keyboardH,
      required double composerH,
    });

/// Builds the emote picker overlay for the computed sheet box height,
/// inset from the stack edges (above the glass pill, or into the chat pane).
typedef EmotePickerBuilder =
    Widget Function(
      BuildContext context, {
      required double sheetBoxHeight,
      required EdgeInsets inset,
    });

/// Below this box height the keyboard leaves too little room for the chrome,
/// so the app bar and channel tabs collapse instantly (like DankChat) and the
/// chat keeps enough room instead of overflowing. Tuned so portrait phones
/// and roomy landscape tablets keep the bar.
const double kKeyboardChromeCollapseBelowHeight = 300.0;

/// Collapse the top chrome when the keyboard eats so much vertical space
/// that the chat would overflow.
bool collapseChromeForKeyboard({
  required double keyboardH,
  required double maxHeight,
}) => keyboardH > 0 && maxHeight < kKeyboardChromeCollapseBelowHeight;

/// Layout assembly for the chat screen: body stack plus composer.
///
/// Geometry rides the stock Scaffold resize, exactly like a bare Scaffold:
/// a keyboard tick only relayouts, it never rebuilds the body. Keyboard
/// decisions (chrome collapse, video hide, pill) read the settled open
/// height, so they flip once when a gesture starts or ends, never
/// mid-animation. All content comes in as builders/widgets so this file
/// holds geometry only, no chat logic.
class ChatBody extends StatefulWidget {
  const ChatBody({
    super.key,
    required this.bodyBuilder,
    required this.threadPanel,
    required this.mentionsPanel,
    required this.modViewPanel,
    required this.emotePickerBuilder,
    required this.autocomplete,
    required this.emoteMaxFraction,
    this.liquidGlass = false,
    this.onKeyboardDismissed,
    this.composer,
    this.notice,
    this.replyHeader,
    this.isInPip = false,
    this.bodyReadsKeyboard = true,
    this.composerInPane = false,
  });

  final ChatBodyBuilder bodyBuilder;
  final Widget threadPanel;
  final Widget mentionsPanel;
  final Widget modViewPanel;
  final EmotePickerBuilder emotePickerBuilder;
  final Widget autocomplete;
  final double emoteMaxFraction;
  final Widget? composer;

  /// Floats the composer as a pill above the chat instead of
  /// docking it in flow. Rows slide underneath the blur.
  final bool liquidGlass;

  /// Fired once the keyboard settles closed, so the host can drop input
  /// focus instead of leaving the field focused silently.
  final VoidCallback? onKeyboardDismissed;

  /// System PiP mode: render the body builder output only. Composer,
  /// panels, picker, autocomplete, and notice stay out of the tree so the
  /// OS window shows just the video (the activity is what shrinks).
  final bool isInPip;

  /// Whether [bodyBuilder] reads maxHeight, keyboardH and composerH. When
  /// false a keyboard gesture never rebuilds the body.
  final bool bodyReadsKeyboard;

  /// Docks the composer under the chat pane (via [ComposerPaneSlot] in the
  /// body) instead of across the full width, so a side-by-side stream keeps
  /// the full height. Overlays anchored to the composer follow it.
  final bool composerInPane;

  /// Reply target card floated above the composer. Null when not replying.
  final Widget? replyHeader;

  /// Inline notice bar floating over the chat, anchored above the composer.
  /// In the body stack (not the Scaffold overlay), so it tracks keyboard
  /// and composer height changes by layout instead of a frozen margin.
  final Widget? notice;

  @override
  State<ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<ChatBody>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // Bottom safe area and the list clearance under the pill. Both ease when
  // the system bars or the pill come and go (fullscreen, input toggle)
  // instead of jumping; keyboard ticks still move them directly.
  late final _bottomPad = _Eased(this, _onEasedTick);
  late final _clearance = _Eased(this, _onEasedTick);
  double? _lastViewPadBottom;
  bool? _lastPill;

  void _onEasedTick() {
    if (mounted) setState(() {});
  }

  // Stack box height with the keyboard closed, learned during layout.
  double? _fullBoxHeight;

  // Whole ChatBody height with the keyboard closed, learned during layout.
  // It is the same whether the composer docks or floats, so both layouts
  // make the keyboard decisions from one geometry.
  double? _closedBodyH;

  // Settled composer content height, safe area excluded. Measured
  // post-layout: reading inputBarKey.size during build throws every frame.
  double _composerH = 56.0;

  // Exit-animation mount gate: the pill stays in the tree while fading
  // out, then unmounts in AnimatedOpacity.onEnd.
  bool _pillShown = false;
  // Backstop so a missed onEnd cannot leave the pill mounted for the session.
  Timer? _pillHideTimer;
  // Composer the pill last showed. Input toggle-off nulls the composer, so
  // this keeps the field in the pill through its exit fade.
  Widget? _pillComposer;

  // Cached chat body and the inputs it was built from.
  Widget? _body;
  Object? _bodyInputs;
  final _bodyKey = GlobalKey();

  // Measured reply header height. Added to the list clearance so rows clear
  // the floating card without the composer resizing.
  double _replyH = 0;
  final _replyKey = GlobalKey();

  void _cacheReplyH() {
    if (!mounted) return;
    final h = _replyKey.currentContext?.size?.height ?? 0;
    if ((h - _replyH).abs() > 0.5) setState(() => _replyH = h);
  }

  // Keyboard overlap in dp. The Scaffold strips viewInsets from its body,
  // so this reads the view directly on metrics changes; nothing above
  // ChatBody has to rebuild per keyboard tick.
  ui.FlutterView? _boundView;
  ui.FlutterView get _view => _boundView!;
  double _rawH = 0;

  // True from the first keyboard tick until it settles closed. A system-bar
  // change during a keyboard transition snaps the nav pad instead of easing:
  // the Scaffold already moves the body with the keyboard, so an ease on top
  // reads as a bounce.
  bool _keyboardEngaged = false;

  // Keyboard height the decisions read: the learned open height from the
  // first tick of an open, the real one once it settles, zero once closed.
  double _liftH = 0;

  // Holds from the first keyboard tick until it settles, so glass surfaces
  // paint a snapshot instead of a live backdrop while the chat moves.
  final _glassFreeze = ValueNotifier<GlassFreeze?>(null);
  final _chromeKey = GlobalKey();
  final _composerKey = GlobalKey();
  ui.Image? _frozenImage;
  // Frees the snapshot once the surfaces' fade back to live glass is done.
  // Frame-timed like that fade, so a stall in frames (app hidden) cannot
  // dispose an image a surface still paints.
  late final _release =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 400),
      )..addStatusListener((s) {
        if (s == AnimationStatus.completed) _releaseFrozen();
      });
  double _learnedH = 0;
  // A composer tap after the keyboard closes asks for it again before the
  // IME's first tick lands, so the pending settle must not unfocus.
  bool _retapped = false;
  // Whether the last tick moved up. Only an opening settles at the real
  // height; a close that stalls mid-way must not be learned.
  bool _opening = false;
  double _persistedH = 0;
  Timer? _settleTimer;

  // Keeps a frame requested while the keyboard moves. Each inset tick lands
  // inside Android's frame; a frame requested only then misses that vsync,
  // so the composer would draw every other tick (30fps).
  late final _keyboardPump = createTicker((_) {});

  double _readRawH() => _view.viewInsets.bottom / _view.devicePixelRatio;

  // Last learned open height, persisted so decisions start right even on a
  // cold start. Re-learned every session, so a stale value self-corrects.
  void _loadLearnedHeight() async {
    try {
      final prefs = await Prefs.load();
      final v = prefs.keyboardSettledHeight;
      if (v > 50 && v < 1500 && _learnedH == 0) {
        _learnedH = v;
        _persistedH = v;
      }
    } catch (_) {}
  }

  void _saveLearnedHeight(double v) {
    if (v <= 50 || v >= 1500) return;
    if ((v - _persistedH).abs() < 10) return;
    _persistedH = v;
    unawaited(
      Prefs.load()
          .then((prefs) => prefs.setKeyboardSettledHeight(v))
          .catchError((Object _) {}),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLearnedHeight();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Seeds the keyboard height only when the view binds. Re-reading it on
    // every dependency change would absorb keyboard ticks that
    // didChangeMetrics must see, including the one that lands on closed.
    final view = View.of(context);
    if (identical(view, _boundView)) return;
    _boundView = view;
    _rawH = _readRawH();
    if (_rawH > 0.5) _keyboardEngaged = true;
    if (_rawH > 0.5 && _liftH == 0) {
      _liftH = _rawH;
      _learnedH = _rawH;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settleTimer?.cancel();
    _pillHideTimer?.cancel();
    _keyboardPump.dispose();
    _release.dispose();
    _frozenImage?.dispose();
    _glassFreeze.dispose();
    _bottomPad.dispose();
    _clearance.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final raw = _readRawH();
    // Sub-pixel ticks are noise, except the one that crosses into or out of
    // closed: IMEs ease out in tiny steps, so that crossing can be one.
    if ((raw - _rawH).abs() < 0.5 && (raw <= 0.5) == (_rawH <= 0.5)) return;
    final wasClosed = _rawH <= 0.5;
    _opening = raw > _rawH;
    _rawH = raw;
    if (raw > 0.5) _keyboardEngaged = true;
    _settleTimer?.cancel();
    if (!_keyboardPump.isActive) _keyboardPump.start();
    if (widget.liquidGlass) _freezeGlass();
    if (raw <= 0.5) {
      _retapped = false;
      if (_liftH != 0) setState(() => _liftH = 0);
    } else if (wasClosed) {
      // Opening: commit the learned height at once so the decisions see the
      // final geometry from the first tick.
      final target = _learnedH > 0 ? _learnedH : raw;
      if ((_liftH - target).abs() > 0.5) setState(() => _liftH = target);
    }
    // A landed close settles fast so the dismiss unfocus follows promptly;
    // the short wait still lets an IME switch (a blip to zero) reopen first.
    final settle = Duration(milliseconds: raw <= 0.5 ? 40 : 120);
    _settleTimer = Timer(settle, () {
      if (!mounted) return;
      _keyboardPump.stop();
      _glassFreeze.value = null;
      if (_frozenImage != null) _release.forward(from: 0);
      // Unfocusing mid-animation races the IME and the next open overshoots,
      // so it waits for the close to settle; a reopen cancels it.
      if (_rawH <= 0.5) {
        _keyboardEngaged = false;
        if (!_retapped) widget.onKeyboardDismissed?.call();
        _retapped = false;
        return;
      }
      if (_opening) {
        _learnedH = _rawH;
        _saveLearnedHeight(_rawH);
      }
      if ((_liftH - _rawH).abs() > 0.5) setState(() => _liftH = _rawH);
    });
  }

  void _releaseFrozen() {
    _frozenImage?.dispose();
    _frozenImage = null;
  }

  // Snapshots the last frame: between ticks nothing is dirty yet, so the
  // boundary's layer still holds it. A fade still running shows in the
  // snapshot, so a new gesture picks up exactly what is on screen.
  void _freezeGlass() {
    if (_glassFreeze.value != null) return;
    _release.stop();
    final boundary =
        _chromeKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || !boundary.hasSize) return;
    var dirty = false;
    assert(() {
      dirty = boundary.debugNeedsPaint;
      return true;
    }());
    if (dirty) return;
    final pr = _view.devicePixelRatio;
    final old = _frozenImage;
    final image = _frozenImage = boundary.toImageSync(pixelRatio: pr);
    _glassFreeze.value = GlassFreeze(image, boundary, pr);
    // The surfaces switched images above; the old one goes after a frame.
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  /// Room above the composer the keyboard decisions read: the settled open
  /// room while the keyboard is up, [closed] otherwise.
  double _decisionHeight(double closed, double composerH) {
    final full = _closedBodyH;
    if (_liftH <= 0 || full == null) return closed;
    return full - _liftH - composerH;
  }

  // Where the in-pane composer sits in the body stack: its side insets and
  // its top's height above the stack bottom. Measured post-layout.
  EdgeInsets _paneInsets = EdgeInsets.zero;

  void _cachePaneInsets() {
    if (!mounted || !widget.composerInPane) return;
    final bar = inputBarKey.currentContext?.findRenderObject();
    final stack = _chromeKey.currentContext?.findRenderObject();
    if (bar is! RenderBox || stack is! RenderBox) return;
    if (!bar.hasSize || !stack.hasSize) return;
    final at = bar.localToGlobal(Offset.zero, ancestor: stack);
    final insets = EdgeInsets.fromLTRB(
      at.dx,
      0,
      stack.size.width - at.dx - bar.size.width,
      stack.size.height - at.dy,
    );
    bool moved(double a, double b) => (a - b).abs() > 0.5;
    if (moved(insets.left, _paneInsets.left) ||
        moved(insets.right, _paneInsets.right) ||
        moved(insets.bottom, _paneInsets.bottom)) {
      setState(() => _paneInsets = insets);
    }
  }

  void _cacheComposerH() {
    if (!mounted || widget.composer == null) return;
    final h = inputBarKey.currentContext?.size?.height;
    if (h == null) return;
    // inputBarKey sits on the padded wrapper, so subtract its bottom inset to
    // cache the content height alone. The safe area is re-added from live
    // MediaQuery at build, so the list clearance cannot lag the keyboard.
    final wrapper = inputBarKey.currentWidget;
    final padBottom = wrapper is Padding
        ? wrapper.padding.resolve(TextDirection.ltr).bottom
        : 0.0;
    final contentH = h - padBottom;
    if ((contentH - _composerH).abs() > 0.5) {
      setState(() => _composerH = contentH);
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardH = _liftH;
    // The keyboard shrinks padding but never viewPadding, so a viewPadding
    // change means the system bars moved: ease that, follow the keyboard.
    // While a keyboard transition is in flight, snap instead: the Scaffold
    // is already moving the body, and easing the pad on top bounces.
    final viewPadBottom = MediaQuery.viewPaddingOf(context).bottom;
    final barsMoved =
        !_keyboardEngaged &&
        _lastViewPadBottom != null &&
        viewPadBottom != _lastViewPadBottom;
    _lastViewPadBottom = viewPadBottom;
    final bottomPad = _bottomPad.resolve(
      MediaQuery.paddingOf(context).bottom,
      animate: barsMoved,
    );
    final size = MediaQuery.sizeOf(context);
    final composer = widget.composer;
    // Cache the settled composer height after layout for keyboard-room
    // math; converges after one extra frame on height changes.
    if (composer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _cacheComposerH();
        _cachePaneInsets();
      });
    }
    if (widget.replyHeader != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _cacheReplyH());
    }
    final decisionH = _decisionHeight(
      _fullBoxHeight ?? size.height,
      composer == null ? 0 : _composerH,
    );
    final hideChromeForKeyboard = collapseChromeForKeyboard(
      keyboardH: keyboardH,
      maxHeight: decisionH,
    );
    // Glass pill footprint, shared with the list bottom padding upstream.
    // Independent of the keyboard, so focusing never reshapes the composer.
    final pane = widget.composerInPane && composer != null && !widget.isInPip;
    final pill =
        !pane &&
        widget.liquidGlass &&
        composer != null &&
        !widget.isInPip &&
        !MediaQuery.highContrastOf(context);
    // Composer footprint: content plus the live safe area, and the pill
    // margin only while floating. Composed at build so the clearance tracks
    // the keyboard inset on the same frame instead of lagging one frame.
    final composerH = composer == null
        ? 0.0
        : _composerH + bottomPad + (pill ? kGlassComposerMargin : 0.0);
    final pillH = glassComposerOverlayHeight(composerH);
    // Rows under the pill ease out of or into its space when it comes and
    // goes; composer growth and keyboard ticks move it directly.
    final pillFlipped = _lastPill != null && pill != _lastPill;
    _lastPill = pill;
    final clearance = _clearance.resolve(
      pill ? pillH : 0.0,
      animate: pillFlipped,
    );
    if (pill) {
      _pillShown = true;
      _pillComposer = composer;
      _pillHideTimer?.cancel();
      _pillHideTimer = null;
    } else if (_pillShown && _pillHideTimer == null) {
      // Backstop for a missed AnimatedOpacity.onEnd: otherwise the pill can
      // stay mounted with its IgnorePointer copy sitting over the composer.
      _pillHideTimer = Timer(const Duration(milliseconds: 240), () {
        _pillHideTimer = null;
        if (mounted) setState(() => _pillShown = false);
      });
    }
    if (!_pillShown) _pillComposer = null;
    // Rebuilt only when its inputs change, so keyboard ticks (including the
    // safe-area ticks that rebuild ChatBody) reuse the same instance and
    // the body subtree skips rebuilding. The body reads the content height
    // without the live safe area; the pill clearance reaches its lists
    // through GlassChromeScope. A body that ignores the keyboard numbers
    // gets constants, so a gesture leaves the cache intact.
    final keyed = widget.bodyReadsKeyboard && !widget.isInPip;
    final inputs = (
      widget.bodyBuilder,
      widget.isInPip ? false : hideChromeForKeyboard,
      size.width,
      keyed ? decisionH : 0.0,
      keyed ? keyboardH : 0.0,
      !keyed || composer == null
          ? 0.0
          : _composerH + (pill ? kGlassComposerMargin : 0.0),
    );
    if (inputs != _bodyInputs) {
      _bodyInputs = inputs;
      final (builder, hide, width, height, kb, bodyComposerH) = inputs;
      // Its own context, so MediaQuery reads inside the body rebuild it
      // directly instead of going stale behind this cache. The key carries
      // that context across the PiP reparent: cached channel pages and rows
      // hold it, and a remount would leave them on a dead one.
      _body = Builder(
        key: _bodyKey,
        builder: (context) => builder(
          context,
          hideChromeForKeyboard: hide,
          maxWidth: width,
          maxHeight: height,
          keyboardH: kb,
          composerH: bodyComposerH,
        ),
      );
    }
    final body = _body!;
    // Overlays anchored to the composer: above the pill or in-flow bar, or
    // within the chat pane when the composer docks there.
    final anchor = pane ? _paneInsets : EdgeInsets.only(bottom: clearance);
    final reply = Positioned(
      key: const ValueKey('reply_header'),
      left: anchor.left + (pill ? kGlassComposerMargin : 8.0) - 4,
      right: anchor.right + (pill ? kGlassComposerMargin : 8.0) - 4,
      bottom: anchor.bottom,
      child: NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _cacheReplyH());
          return true;
        },
        child: SizeChangedLayoutNotifier(
          child: KeyedSubtree(
            key: _replyKey,
            child: widget.replyHeader ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
    // Autocomplete dropdown - floats above chat, anchored just above the
    // message input, 60% width like DankChat's popup.
    final anchorW = size.width - anchor.left - anchor.right;
    final autocomplete = Positioned(
      key: const ValueKey('autocomplete'),
      bottom: anchor.bottom,
      left: anchor.left,
      child: SizedBox(
        width: (anchorW * 0.6).clamp(0.0, 340.0),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: size.height * 0.25),
          child: widget.autocomplete,
        ),
      ),
    );
    // Chat notice - floats over the chat, anchored just above the composer.
    // Overlay, not column content, so showing it never resizes the chat.
    final notice = widget.notice == null
        ? null
        : Positioned(
            key: const ValueKey('chat_notice'),
            bottom: anchor.bottom,
            left: anchor.left,
            right: anchor.right,
            child: widget.notice!,
          );
    // The composer, keyed so the field moves intact across the pill and
    // in-flow paths: a rebuilt EditableText closes the input connection and
    // iOS drops the keyboard. Each path rings its own shell with the glow.
    Widget composerSlot(Widget? field) => field == null
        ? const SizedBox.shrink()
        : KeyedSubtree(
            key: _composerKey,
            child: Listener(
              onPointerDown: (_) => _retapped = true,
              child: field,
            ),
          );
    // Floating composer pill. The list pads by pillH upstream
    // so the newest rows clear it and slide underneath while scrolling. The
    // size notifier keeps the measurement fresh when inner listenables
    // resize the pill without a ChatBody rebuild (status text, reply banner,
    // extra input lines). Show/hide fades and slides; the pill stays
    // mounted through the exit fade via [_pillShown].
    final pillOverlay = !(pill || _pillShown)
        ? null
        : Positioned(
            key: const ValueKey('composer_pill'),
            left: kGlassComposerMargin,
            right: kGlassComposerMargin,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !pill,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: pill ? 1.0 : 0.0,
                onEnd: () {
                  if (!pill && mounted) {
                    setState(() => _pillShown = false);
                  }
                },
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  offset: pill ? Offset.zero : const Offset(0, 0.4),
                  child: Padding(
                    key: inputBarKey,
                    padding: EdgeInsets.only(
                      bottom: bottomPad + kGlassComposerMargin,
                    ),
                    child: NotificationListener<SizeChangedLayoutNotification>(
                      onNotification: (_) {
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _cacheComposerH(),
                        );
                        return true;
                      },
                      child: SizeChangedLayoutNotifier(
                        child: ComposerFocusGlow(
                          enabled: true,
                          radius: kGlassComposerRadius,
                          child: glassPill(child: composerSlot(_pillComposer)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
    // The composer docked under the chat pane. Same keys as the other two
    // paths, and gated on !_pillShown, so only one copy mounts and focus
    // survives the move.
    final paneSlot = !pane || _pillShown
        ? null
        : Padding(
            key: inputBarKey,
            padding: EdgeInsets.only(bottom: bottomPad),
            child: NotificationListener<SizeChangedLayoutNotification>(
              onNotification: (_) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _cacheComposerH();
                  _cachePaneInsets();
                });
                return true;
              },
              child: SizeChangedLayoutNotifier(
                child: ComposerFocusGlow(
                  enabled: widget.liquidGlass,
                  radius: 0,
                  child: composerSlot(composer),
                ),
              ),
            ),
          );
    // No manual lift: the Scaffold shrank the body, so the composer sits
    // above the keyboard at settled constraints with no second animator
    // to cross the system motion. The key stays for post-layout measuring.
    final column = Column(
      children: [
        Expanded(
          child: widget.isInPip
              ? body
              : GlassChromeScope(
                  bottomClearance: clearance,
                  listExtra: widget.replyHeader != null ? _replyH : 0,
                  freeze: _glassFreeze,
                  // The glass freeze snapshots this boundary. The fill makes
                  // the snapshot opaque, matching the Scaffold behind it.
                  child: RepaintBoundary(
                    key: _chromeKey,
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      // Per keyboard tick only this builder reruns; every
                      // child but the picker is a prebuilt instance.
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final statusBarH = statusBarHeight(context);
                          if (_rawH <= 0.5) {
                            _fullBoxHeight = constraints.maxHeight;
                          }
                          // The glass pill floats inside this box, so the
                          // sizing below measures the box as if the composer
                          // were in flow (opaque), then raises the picker
                          // above the pill without moving its top.
                          final inFlowH = pill
                              ? _composerH + bottomPad
                              : pane
                              ? _paneInsets.bottom
                              : 0.0;
                          final fullBoxH =
                              (_fullBoxHeight ?? constraints.maxHeight) -
                              statusBarH -
                              inFlowH;
                          // Full-box canvas for the sheet: the Positioned box may
                          // run past the top of the shrunk Stack (clipped,
                          // harmless) so the Draggable fractions keep measuring
                          // against the full box and the sheet anchors to the
                          // bottom, above the keyboard.
                          final maxFitBoxH =
                              (constraints.maxHeight - statusBarH - inFlowH) /
                              widget.emoteMaxFraction;
                          final fitH = fullBoxH < maxFitBoxH
                              ? fullBoxH
                              : maxFitBoxH;
                          final sheetBoxHeight = pill
                              ? fitH -
                                    (clearance - inFlowH) /
                                        widget.emoteMaxFraction
                              : fitH;
                          return Stack(
                            clipBehavior: Clip.hardEdge,
                            children: [
                              ComposerPaneScope(slot: paneSlot, child: body),
                              reply,
                              widget.threadPanel,
                              widget.mentionsPanel,
                              widget.modViewPanel,
                              widget.emotePickerBuilder(
                                context,
                                sheetBoxHeight: sheetBoxHeight,
                                inset: pane
                                    ? _paneInsets
                                    : EdgeInsets.only(
                                        bottom: pill ? clearance : 0,
                                      ),
                              ),
                              autocomplete,
                              ?notice,
                              ?pillOverlay,
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
        ),
        if (!widget.isInPip)
          // Safe area stays outside AnimatedSize so the nav-bar collapse is
          // not animated. The in-flow composer is gated on !_pillShown so the
          // pill and the in-flow never mount together: one shared inputBarKey
          // keeps the composer's FocusNode alive across the hand-off.
          Padding(
            padding: EdgeInsets.only(bottom: pill || pane ? 0.0 : bottomPad),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              alignment: Alignment.bottomCenter,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: !pill && !pane && composer != null ? 1.0 : 0.0,
                child: pill || pane || _pillShown || composer == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: inputBarKey,
                        padding: EdgeInsets.zero,
                        child: ComposerFocusGlow(
                          enabled: widget.liquidGlass,
                          radius: 0,
                          child: composerSlot(composer),
                        ),
                      ),
              ),
            ),
          ),
      ],
    );
    // Per keyboard tick this reruns and returns the same prebuilt column.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_rawH <= 0.5) _closedBodyH = constraints.maxHeight;
        return column;
      },
    );
  }
}

/// A number that eases to a new target over 220ms instead of jumping, or
/// snaps when told to. Read during build; [onTick] rebuilds while it runs.
class _Eased {
  _Eased(TickerProvider vsync, VoidCallback onTick)
    : _ctrl = AnimationController(
        vsync: vsync,
        duration: const Duration(milliseconds: 220),
      )..addListener(onTick);

  final AnimationController _ctrl;
  bool _seeded = false;
  double _from = 0;
  double _to = 0;

  /// The controller starts after the frame (it notifies on start, which
  /// would rebuild mid-build), so the building frame still shows [_from].
  bool _startPending = false;

  double get value {
    if (_startPending) return _from;
    if (!_ctrl.isAnimating) return _to;
    return ui.lerpDouble(_from, _to, Curves.easeInOut.transform(_ctrl.value))!;
  }

  double resolve(double target, {required bool animate}) {
    if (!_seeded) {
      _seeded = true;
      _to = target;
    }
    if (target == _to) return value;
    if (animate) {
      _from = value;
      _to = target;
      if (!_startPending) {
        _startPending = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_startPending) return;
          _startPending = false;
          _ctrl.forward(from: 0);
        });
      }
    } else {
      _startPending = false;
      _ctrl.stop();
      _to = target;
    }
    return value;
  }

  void dispose() {
    _startPending = false;
    _ctrl.dispose();
  }
}

/// Carries the docked composer from [ChatBody] down to the chat pane.
class ComposerPaneScope extends InheritedWidget {
  const ComposerPaneScope({
    super.key,
    required this.slot,
    required super.child,
  });

  final Widget? slot;

  @override
  bool updateShouldNotify(ComposerPaneScope oldWidget) =>
      slot != oldWidget.slot;
}

/// Where a side chat pane shows the docked composer; empty otherwise. Only
/// this widget rebuilds when the composer does, not the pane around it.
class ComposerPaneSlot extends StatelessWidget {
  const ComposerPaneSlot({super.key});

  @override
  Widget build(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ComposerPaneScope>()?.slot ??
      const SizedBox.shrink();
}
