# Backlog

Release wrap-up triage, kept separate so the live plan stays focused. The chat-state
split landed; the connection-manager/pipeline split is the next structural slice (see
PLAN.md).

## ASAP next update

- Emote resilience: bounded retry on fail, low-res placeholder when tier goes
  Low to High, uncapped FPS follows display refresh.
- Perf: image-embed cache bypass plus double linkify, action-message recolor,
  double tokenize, GIF regex hoist, explicit cacheExtent, checker parity by id.
- Visual: border flicker on tab in, tab strip stretch, double Connected on iOS,
  timestamp gutter width, reply colon on empty preview.
- UX consistency: one slider contract, one empty state, one error with Retry,
  welcome copy fix, InkWell audit, More menu Close, macro Save errors.
- Verify own-message send ack if the read socket dies mid-send.

## Near future

- Widget test prune. 84 candidates cataloged across widgets_test plus the five
  smaller widget files. Keep reconnect dedup, tombstone, thread truncation,
  pause hold, swipe hysteresis, JOIN gate. Only prune when tests churn or CI
  gets slow.
- Notification double-init plus stale map, player and sheet controller swaps,
  subscribe-then-part race.
- Short architecture and data flow doc.
- Mod View 52-issue triage plus Points CRUD decision.

## Far future, major reworks only

- Split remaining god objects: connection manager, channel manager, emote manager,
  mod_view. Private state with verbs only. Single ingest path. Single moderation
  formatter. Table-driven EventSub. The store split already landed.
- UI: single tile cache owner, one tile config for main, thread, mentions,
  history. Split mod_view per tab. Single panel shell. Single input borrow
  stack. Stable video slot across layout modes.
- Features: VOD replay, dual-pane, chat search, full l10n, accessibility pass,
  home widget, iOS push, stream battery saver. See I18N.md for localization.

## Rejected for right before release (too high scope)

- Android release signing fallback when key.properties is missing.
- English-only declaration plus F-Droid changelog docs.
- Switching-account connecting hint rework.
- Join dialog validation plus progress plus n/50 count.
- Full widget test gutting.
- All god-object splits and structural UI reworks. (Superseded for chat state: the
  store split landed.)
