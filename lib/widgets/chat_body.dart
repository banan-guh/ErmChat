import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../composer/composer_bar.dart';
import '../util/insets.dart';
import '../util/prefs.dart';
import 'glass_chrome.dart';
import 'design_tokens.dart';
import 'message_input.dart' show MessageInput;

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
/// inset from the stack edges (above the floating island, or into the chat
/// pane).
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
/// decisions (chrome collapse, video hide, island) read the settled open
/// height, so they flip once when a gesture starts or ends, never
/// mid-animation. All content comes in as builders/widgets so this file
/// holds geometry only, no chat logic.
class ChatBody extends StatefulWidget {
  /// Width of the island's side action column.
  static const double sideActionWidth = 56;

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
    this.keyboardHidesButtons = false,
    this.islandFlush = false,
    this.classic = false,
    this.busyListenable,
    this.isBusy,
    this.uploadProgress,
    this.onKeyboardDismissed,
    this.composer,
    this.bottomBar,
    this.sideAction,
    this.loneAction,
    this.islandFooter,
    this.islandFooterHeightFor,
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

  /// Chrome below the composer: threads, bell, overflow and settings. Sits
  /// inside the composer island and rides up with the keyboard (or is clipped
  /// away under [keyboardHidesButtons]).
  final Widget? bottomBar;

  /// A tall action down the island's right edge, beside the field and the
  /// row (send, while the row stays up as you type). Fills its column.
  final Widget? sideAction;

  /// The one action left when there is no island (the view menu, with the
  /// input hidden and the menu placed in the row). Floats at the corner.
  final Widget? loneAction;

  /// A line at the island's foot across its full width, under the row and
  /// the side action (the channel status). Hides with the row.
  final Widget? islandFooter;

  /// The [islandFooter] height a given channel shows, so each chat page is
  /// laid out for its own island before the switch lands.
  final double Function(String channel)? islandFooterHeightFor;

  /// Floats the composer as an island over the chat instead of docking it
  /// in flow. Rows slide underneath the frosted shell.
  final bool liquidGlass;

  /// Hides the button row while the keyboard is up instead of pushing it,
  /// by clipping the island from below as the keyboard rises.
  final bool keyboardHidesButtons;

  /// The island runs edge to edge and down under the nav bar, rounded only
  /// on top, instead of floating a margin in. Takes no hidden row.
  final bool islandFlush;

  /// The field sits edge to edge on the chat's own background, with no
  /// island shell around it (ComposerStyle.classic).
  final bool classic;

  /// Rings the island with the stock loading motion while [isBusy] holds,
  /// re-read whenever [busyListenable] fires. Null for no ring.
  final Listenable? busyListenable;
  final bool Function()? isBusy;

  /// The running upload's share sent, from 0 to 1, drawn as a bar along the
  /// island's top edge. Null while no upload runs.
  final ValueListenable<double?>? uploadProgress;

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
  // Bottom safe area and the list clearance under the island. Both ease when
  // the system bars or the island come and go (fullscreen, input toggle)
  // instead of jumping; keyboard ticks still move them directly.
  late final _bottomPad = _Eased(this, _onEasedTick);
  late final _clearance = _Eased(this, _onEasedTick);
  double? _lastViewPadBottom;
  bool? _lastFloating;

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

  // Measured island content height (field plus button row) and its outer
  // height (content plus any focus-ring border). The row feeds the hidden
  // clip; the outer height feeds the list clearance.
  double _islandH = 56.0;
  double _islandOuterH = 56.0;

  // The nav bar pad a flush island paid inside its shell in the last build,
  // and the pad inside [_islandOuterH] when it was measured. The clearance
  // swaps the measured pad for the live one, so a keyboard closing over the
  // nav bar moves the rows on the same frame as the island.
  double _padInShell = 0;
  double _padInOuter = 0;
  // Outer minus content: the shell's border and padding, which a clipped
  // island can't measure.
  double _islandShellH = 0;

  /// [value], or [fallback] when it is NaN or infinite. One non-finite input
  /// would stick in the cached heights (NaN never compares as a change), so
  /// it is dropped.
  static double _finite(double value, double fallback) =>
      value.isFinite ? value : fallback;

  final _islandKey = GlobalKey();
  final _islandOuterKey = GlobalKey();

  // The field's animated slot, and the island below it (row plus footer).
  // Both come from one measure, so a field growing inside its animation
  // never reads as a shorter row and lets the hidden row peek out.
  final _flowKey = GlobalKey();
  double? _rowH;

  // Keyboard height by which the hidden row is gone (nav bar plus row), or
  // zero when the row never hides.
  double _hideSpan = 0;

  // How much of the row the shortened island hides this frame.
  double _rowClip = 0;

  // Measured height of the island's footer (the channel status), which the
  // pages' clearance leaves out: each page adds its own channel's instead.
  double _footerH = 0;
  final _footerKey = GlobalKey();

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
    final size = _replyKey.currentContext?.size?.height ?? 0;
    final h = _finite(size, _replyH);
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

  final _chromeKey = GlobalKey();
  final _composerKey = GlobalKey();
  double _learnedH = 0;
  // A composer tap after the keyboard closes asks for it again before the
  // IME's first tick lands, so the pending settle must not unfocus.
  bool _retapped = false;
  // What held focus as the keyboard began to close. A field focused since
  // (search opened from a menu that took focus) asked for the keyboard, so
  // that close is no dismiss.
  FocusNode? _focusAtClose;
  // Whether the last tick moved up. Only an opening settles at the real
  // height; a close that stalls mid-way must not be learned.
  bool _opening = false;
  double _persistedH = 0;
  Timer? _settleTimer;

  // Keeps a frame requested while the keyboard moves. Each inset tick lands
  // inside Android's frame; a frame requested only then misses that vsync,
  // so the composer would draw every other tick (30fps).
  late final _keyboardPump = createTicker((_) {});

  /// The keyboard height in logical pixels. A view without a pixel ratio
  /// (detaching) reads as no change, since one NaN would stick in every
  /// cached height below.
  double _readRawH() =>
      _finite(_view.viewInsets.bottom / _view.devicePixelRatio, _rawH);

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
    _keyboardPump.dispose();
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
    // The hidden row slides out over the keyboard's first [_hideSpan]; only
    // those ticks rebuild, since the padding stops changing past the nav bar.
    if ((raw < _rawH ? raw : _rawH) < _hideSpan) setState(() {});
    final wasClosed = _rawH <= 0.5;
    if (raw < _rawH) {
      _focusAtClose ??= FocusManager.instance.primaryFocus;
    } else {
      _focusAtClose = null;
    }
    _opening = raw > _rawH;
    _rawH = raw;
    if (raw > 0.5) _keyboardEngaged = true;
    _settleTimer?.cancel();
    if (!_keyboardPump.isActive) _keyboardPump.start();
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
      // Unfocusing mid-animation races the IME and the next open overshoots,
      // so it waits for the close to settle; a reopen cancels it.
      if (_rawH <= 0.5) {
        _keyboardEngaged = false;
        final before = _focusAtClose;
        _focusAtClose = null;
        final now = FocusManager.instance.primaryFocus;
        if (!identical(now, before)) {
          // The field's request landed mid-close and the IME dropped it.
          now?.context
              ?.findAncestorStateOfType<EditableTextState>()
              ?.requestKeyboard();
        } else if (!_retapped) {
          widget.onKeyboardDismissed?.call();
        }
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
    if (!h.isFinite) return;
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

  void _cacheIslandH() {
    if (!mounted) return;
    // A non-finite size reads as unmeasured: the caches only update on a
    // change, and NaN never compares as one, so it would stick.
    double? height(GlobalKey key) {
      final h = key.currentContext?.size?.height;
      return h == null || h.isFinite ? h : null;
    }

    final h = height(_islandKey);
    if (h != null && (h - _islandH).abs() > 0.5) {
      setState(() => _islandH = h);
    }
    final flow = height(_flowKey);
    if (h != null && flow != null) {
      final row = h - flow;
      if (_rowH == null || (row - _rowH!).abs() > 0.5) {
        setState(() => _rowH = row);
      }
    }
    // The clip leaves the island's own layout whole (field and footer), so
    // it measures true under the keyboard too.
    final footer = height(_footerKey) ?? 0;
    final footerDelta = footer - _footerH;
    // A shortened island would read as a smaller one, so a clipped island
    // takes its full height from the unclipped content plus the shell
    // around it, measured while unclipped.
    final measured = height(_islandOuterKey);
    if (_rowClip <= 0 && measured != null && h != null) {
      _islandShellH = measured - h;
    }
    final outer = _rowClip > 0 ? (h ?? _islandH) + _islandShellH : measured;
    if (outer != null) _padInOuter = _padInShell;
    if (outer != null && (outer - _islandOuterH).abs() > 0.5) {
      setState(() => _islandOuterH = outer);
    }
    if (footerDelta.abs() > 0.5) {
      setState(() => _footerH = footer);
    }
  }

  /// [content] with the upload bar across its top edge, clipped to the
  /// island's [radius]; it fades out full once the upload ends.
  Widget _withUploadBar(Widget content, BorderRadius radius) {
    final progress = widget.uploadProgress;
    if (progress == null) return content;
    return Stack(
      children: [
        content,
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRRect(
              borderRadius: radius,
              child: Align(
                alignment: Alignment.topCenter,
                child: ValueListenableBuilder<double?>(
                  valueListenable: progress,
                  builder: (_, sent, _) => AnimatedOpacity(
                    opacity: sent == null ? 0 : 1,
                    duration: Motion.normal,
                    child: LinearProgressIndicator(
                      value: sent ?? 1,
                      minHeight: 3,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Settled decisions read _liftH; the hidden clip reads the raw per-frame
    // height so the row slides out under the rising keyboard.
    final keyboardH = _liftH;
    final frameKb = _rawH;
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
    // The pane docks the composer inside the chat pane; the island covers the
    // full-width paths.
    final pane = widget.composerInPane && composer != null && !widget.isInPip;
    // The bottom bar owns the safe area when present, and the island pays it
    // outside its shell, so the composer never pays it twice.
    final hasBar = widget.bottomBar != null && !widget.isInPip;
    final glass = widget.liquidGlass && !MediaQuery.highContrastOf(context);
    // Hidden-by-keyboard applies to the full-width island only.
    final classic = widget.classic && !pane && !widget.isInPip;
    final flush = (widget.islandFlush || classic) && !pane && !widget.isInPip;
    final hidden =
        widget.keyboardHidesButtons && !flush && !pane && !widget.isInPip;
    final showIsland = !widget.isInPip && !pane && (composer != null || hasBar);
    // The island floats over the chat in every style, so rows scroll on
    // behind it.
    final floating = showIsland;
    // Cache the island height; it feeds the clearance and the hidden clip.
    if (showIsland || pane) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _cacheIslandH());
    }
    // The row is whatever sits below the field inside the island, the
    // status footer included.
    final rowH = composer == null
        ? _islandH
        : (_rowH ?? _islandH - _composerH).clamp(0.0, _islandH);
    final islandBottom = flush ? 0.0 : kComposerIslandMargin + bottomPad;
    // Hidden mode pins the island above the nav bar (the padding shrinks
    // under the keyboard, the nav bar does not) and clips the row from below
    // as the keyboard rises past it, so the visible bottom edge rides the
    // keyboard a margin above it. Once the row is gone the field rides too.
    // Offsets are from the body's bottom, which the keyboard already lifts.
    // The Scaffold subtracts the keyboard from the body's viewPadding too,
    // so the nav bar height comes from the view itself.
    final view = View.of(context);
    final navPad = frameKb > 0.5
        ? _finite(view.viewPadding.bottom / view.devicePixelRatio, bottomPad)
        : bottomPad;
    _hideSpan = hidden && floating ? navPad + rowH : 0;
    final clipRow = (frameKb - navPad).clamp(0.0, rowH);
    final push = (frameKb - navPad - rowH).clamp(0.0, double.infinity);
    final hiddenBottom = kComposerIslandMargin + navPad - frameKb + push;
    // Rows under the island ease out of or into its space when it comes and
    // goes; composer growth and keyboard ticks move it directly.
    final floatingFlipped = _lastFloating != null && floating != _lastFloating;
    _lastFloating = floating;
    final clearance = _clearance.resolve(
      !floating
          ? 0.0
          : hidden
          ? hiddenBottom + _islandOuterH
          : flush
          ? _islandOuterH - _padInOuter + bottomPad
          : glassComposerOverlayHeight(_islandOuterH) + bottomPad,
      animate: floatingFlipped,
    );
    // Rebuilt only when its inputs change, so keyboard ticks (including the
    // safe-area ticks that rebuild ChatBody) reuse the same instance and
    // the body subtree skips rebuilding. The body reads the content height
    // without the live safe area; the island clearance reaches its lists
    // through GlassChromeScope. A body that ignores the keyboard numbers
    // gets constants, so a gesture leaves the cache intact.
    final keyed = widget.bodyReadsKeyboard && !widget.isInPip;
    final inputs = (
      widget.bodyBuilder,
      widget.isInPip ? false : hideChromeForKeyboard,
      size.width,
      keyed ? decisionH : 0.0,
      keyed ? keyboardH : 0.0,
      !keyed || composer == null ? 0.0 : _composerH,
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
    // Overlays anchored above the island: the floating clearance, or the
    // pane's measured composer box.
    final anchor = pane ? _paneInsets : EdgeInsets.only(bottom: clearance);
    final sideGap = pane ? 0.0 : kComposerIslandMargin;
    final reply = Positioned(
      key: const ValueKey('reply_header'),
      left: anchor.left + sideGap - 4,
      right: anchor.right + sideGap - 4,
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
    // The composer, keyed so the field moves intact between the docked and
    // floating island paths: a rebuilt EditableText closes the input
    // connection and iOS drops the keyboard.
    Widget composerSlot(Widget? field) => field == null
        ? const SizedBox.shrink()
        : KeyedSubtree(
            key: _composerKey,
            child: Listener(
              onPointerDown: (_) => _retapped = true,
              child: field,
            ),
          );
    // The composer field. One shared inputBarKey keeps the FocusNode alive
    // as the island moves between the docked and floating paths. The size
    // notifier re-measures when inner listenables resize it without a
    // ChatBody rebuild (status text, extra input lines). The outer notifier
    // follows the grow animation, so the island and the list clearance under
    // it re-measure on every frame of it, not only where it starts.
    final flowComposer = NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _cacheIslandH());
        return true;
      },
      child: SizeChangedLayoutNotifier(
        child: AnimatedSize(
          key: _flowKey,
          duration: Motion.normal,
          curve: Motion.move,
          alignment: Alignment.bottomCenter,
          child: composer == null
              ? const SizedBox.shrink()
              : Padding(
                  key: inputBarKey,
                  padding: EdgeInsets.zero,
                  child: NotificationListener<SizeChangedLayoutNotification>(
                    onNotification: (_) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _cacheComposerH();
                        _cachePaneInsets();
                      });
                      return true;
                    },
                    child: SizeChangedLayoutNotifier(
                      child: composerSlot(composer),
                    ),
                  ),
                ),
        ),
      ),
    );
    // Round shell for the island: frosted in glass. Otherwise the focus glow
    // paints the fill, one surface tone above the chat plane, and this clear
    // Material only clips and carries the ink.
    const corner = Radius.circular(kComposerIslandRadius);
    final radius = classic
        ? BorderRadius.zero
        : flush
        ? const BorderRadius.vertical(top: corner)
        : const BorderRadius.all(corner);
    _padInShell = flush ? bottomPad : 0;
    Widget islandShell(Widget child) {
      // Flush, the island pays the nav bar inside its own fill.
      final body = flush
          ? Padding(
              padding: EdgeInsets.only(bottom: bottomPad),
              child: child,
            )
          : child;
      return glass
          ? glassIsland(child: body)
          : Material(
              type: MaterialType.transparency,
              borderRadius: radius,
              clipBehavior: Clip.antiAlias,
              child: body,
            );
    }

    // One island: field and button row in one shell. Hidden mode shortens
    // the shell from below as the keyboard rises, so its rim and corners
    // reshape around what is left instead of being cut off.
    _rowClip = hidden ? clipRow : 0;
    // The footer resizes on its own (a channel switch swaps the status), so
    // it re-measures the island itself rather than waiting on a rebuild.
    final footer = widget.islandFooter == null
        ? null
        : KeyedSubtree(
            key: _footerKey,
            child: NotificationListener<SizeChangedLayoutNotification>(
              onNotification: (_) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _cacheIslandH(),
                );
                return true;
              },
              child: SizeChangedLayoutNotifier(child: widget.islandFooter!),
            ),
          );
    final busyListenable = widget.busyListenable;
    final isBusy = widget.isBusy;
    final showsBusy = busyListenable != null && isBusy != null;
    // A floating island runs loading around its outline. Edge to edge, it is
    // a straight line between the field and the button row.
    Widget ringed(Widget island) => !showsBusy || flush
        ? island
        : IslandBusyRing(
            listenable: busyListenable,
            busy: isBusy,
            child: island,
          );
    final busyLine = !showsBusy || !flush
        ? null
        : SizedBox(
            height: 0,
            child: OverflowBox(
              maxHeight: 3,
              child: ListenableBuilder(
                listenable: busyListenable,
                builder: (_, _) {
                  final busy = isBusy();
                  return AnimatedOpacity(
                    opacity: busy ? 1 : 0,
                    duration: Motion.normal,
                    child: TickerMode(
                      enabled: busy,
                      child: const LinearProgressIndicator(
                        minHeight: 3,
                        backgroundColor: Colors.transparent,
                      ),
                    ),
                  );
                },
              ),
            ),
          );
    // Classic is just the outlined field on the chat's background, so the
    // field's own outline shows focus instead of a tinted shell.
    Widget outer({required Widget child}) => classic
        ? ColoredBox(
            key: _islandOuterKey,
            color: Theme.of(context).scaffoldBackgroundColor,
            child: child,
          )
        : ComposerFocusGlow(
            key: _islandOuterKey,
            shape: glass
                ? RoundedSuperellipseBorder(borderRadius: radius)
                : RoundedRectangleBorder(borderRadius: radius),
            surface: glass
                ? null
                : Theme.of(context).colorScheme.surfaceContainer,
            child: child,
          );
    final island = outer(
      child: islandShell(
        _withUploadBar(
          ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: _islandH > 0
                  ? (1 - _rowClip / _islandH).clamp(0.0, 1.0)
                  : 1,
              child: Column(
                key: _islandKey,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.sideAction == null) ...[
                    flowComposer,
                    ?busyLine,
                    ?widget.bottomBar,
                    ?footer,
                  ] else
                    // The side action runs the island's full height, so its
                    // ink reaches the rim. The column sets the height and the
                    // action fills it, with no intrinsic pass (the field's
                    // LayoutBuilder cannot answer one). The footer spans the
                    // full width under it, so centered text centers on the
                    // whole island.
                    Stack(
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(
                                right: ChatBody.sideActionWidth,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  flowComposer,
                                  ?busyLine,
                                  ?widget.bottomBar,
                                ],
                              ),
                            ),
                            ?footer,
                          ],
                        ),
                        Positioned(
                          top: 0,
                          bottom: 0,
                          right: 0,
                          width: ChatBody.sideActionWidth,
                          child: widget.sideAction!,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          radius,
        ),
      ),
    );
    final islandPad = EdgeInsets.fromLTRB(
      kComposerIslandMargin,
      kComposerGap - kOpaqueComposerGap,
      kComposerIslandMargin,
      kComposerIslandMargin + bottomPad,
    );
    // The composer docked under the chat pane.
    final paneSlot = !pane
        ? null
        : Padding(padding: islandPad, child: ringed(island));
    // Floating island. Hidden mode keeps its top pinned while the shell
    // shortens from below; otherwise it rides the keyboard.
    final floatingIsland = !floating
        ? null
        : Positioned(
            key: const ValueKey('composer_island'),
            left: flush ? 0 : kComposerIslandMargin,
            right: flush ? 0 : kComposerIslandMargin,
            bottom: hidden ? hiddenBottom + clipRow : islandBottom,
            child: ringed(island),
          );
    final lone = widget.loneAction == null || showIsland || pane
        ? null
        : Positioned(
            right: 8,
            bottom: 8,
            height: 40,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                shape: const StadiumBorder(),
              ),
              child: Center(child: widget.loneAction),
            ),
          );
    // Nothing to show: keep the safe area so the chat never runs under the
    // nav bar.
    final emptyPad = (widget.isInPip || pane || showIsland)
        ? null
        : Padding(
            padding: EdgeInsets.only(bottom: bottomPad),
            child: const SizedBox.shrink(),
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
                  // Pages add their own channel's footer through
                  // [GlassChromeScope.footerFor], so a switch moves only
                  // the island.
                  // The classic field's label room is already empty space
                  // above its outline, so it counts toward the list's gap.
                  bottomClearance: clearance > 0.5
                      ? clearance -
                            _footerH -
                            (classic ? MessageInput.labelRoom : 0)
                      : clearance,
                  footerFor: widget.islandFooterHeightFor,
                  footerHeight: _footerH,
                  listExtra: widget.replyHeader != null ? _replyH : 0,
                  glass: glass,
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
                          // The floating island sits inside this box, so the
                          // sizing below measures the box as if the composer
                          // were in flow (docked tall), then anchors the
                          // picker above the island without moving its top.
                          final inFlowH = floating
                              ? _islandOuterH + bottomPad
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
                          final sheetBoxHeight = floating
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
                                        bottom: floating ? clearance : 0,
                                      ),
                              ),
                              autocomplete,
                              ?notice,
                              ?floatingIsland,
                              ?lone,
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
        ),
        // The bare safe-area spacer when there is no island to show. The
        // island lives in the stack above so the chat scrolls underneath it.
        ?emptyPad,
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
    : _ctrl = AnimationController(vsync: vsync, duration: Motion.normal)
        ..addListener(onTick);

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
    return ui.lerpDouble(_from, _to, Motion.move.transform(_ctrl.value))!;
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
