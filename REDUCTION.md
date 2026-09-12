# Code reduction

Status: FINDINGS. A reference for planning, not a frozen execution plan. Numbers are
estimates from a survey pass; verify against the code before acting.

This document records where `lib/` can express the same behavior with less code, and
where a preexisting library can replace bespoke infrastructure. It is the output of a
feature budget pass, three code-reduction passes (emotes, settings/UI, moderation and
commands), and a library survey.

## Status (applied so far)

- **1a dead code: done.** Removed the dead mod section in `message_menu.dart`,
  `showModConfirmDialog`, `decodeWebpPureDart`, and the superseded pure-Dart WebP
  decoder; `isMention`/`isMentionOf` kept because tests use them.
- **1b duplication: done** for the high-confidence rows (semaphores, date helpers,
  `SettingsSectionHeader`, `failureReason`, stash hydration, twitch-sub predicate, 7TV
  sub pairs, FPS prefs).
- **1c: partly done.** Landed `SettingsNavTile`, `confirmDialog`, `showChoiceDialog`,
  the shared IRC/EventSub moderation-copy formatter, `TwitchApi._send`,
  `ModActions` guards, and the `mod_view` guarded-load scaffold. Skipped as stale or
  not identical: `PatternRuleFields`, `_ModEmpty`/`_ModError`, `ModActionPrompter`,
  `EmoteType` tables. Remaining: prefs facade, `SettingsCallbacks`, badge fetch
  skeletons, RIFF/WebP chunk walking, `GenericEmote` rebuild, unlock/override merge.
- **Track 2 (libraries/codegen): deferred** to a separate fork.

## Invariants

- No feature loss. Personal emotes, the emote cache, the broken-emote shim, and the
  stability patches all stay.
- No behavior or visual regression. Extractions must preserve copy, ordering, and
  layout exactly.
- Splitting a god object moves lines; it does not shrink the total. Only true-shrink
  work (dead code, duplication, redundant layers) and library shifts change the count.
- Do not commit generated code. Generated output is excluded from the maintained
  surface, matching the reference apps.

## Where the mass is

`lib/` is 51,786 lines excluding `test/` and vendored `third_party/`.

| Feature | Lines | % |
| --- | ---: | ---: |
| Emotes (manager, cache, providers, image/render, picker) | 8,808 | 17.0% |
| App shell / panels / composer / chrome | 8,046 | 15.5% |
| Chat rendering + message model (rows, spans, tiles, threads) | 6,537 | 12.6% |
| Moderation + Mod View | 5,536 | 10.7% |
| EventSub | 2,567 | 5.0% |
| Settings UI | 2,468 | 4.8% |
| Other (twitch_api, limiter, connectivity, config) | 1,903 | 3.7% |
| Mentions, pings, ignores | 1,858 | 3.6% |
| IRC | 1,720 | 3.3% |
| Media (embeds, uploader, whitelist) | 1,629 | 3.1% |
| Chat-state kernel (`lib/chat`) | 1,587 | 3.1% |
| 7TV paints / cosmetics | 1,414 | 2.7% |
| Commands + macros | 1,412 | 2.7% |
| Auth + accounts | 1,222 | 2.4% |
| Notifications, background, TTS | 1,087 | 2.1% |
| Util | 962 | 1.9% |
| Models | 828 | 1.6% |
| Stream player + PiP + video | 791 | 1.5% |
| Analytics | 612 | 1.2% |
| Search | 421 | 0.8% |
| Badges | 378 | 0.7% |

The top four buckets are 56% of the app. `lib/services/` alone is 17,576 lines (34%),
which is the structural outlier: `emote_manager.dart` 3,144, `chat_connection_manager.dart`
1,649, `twitch_api.dart` 1,488, `command_handler.dart` 1,140, `mod_actions.dart` 884.

## Why we are bigger than peers

References on disk: chatsen (Flutter, 12,419 lines excluding generated `l10n`; 22,025
with it) and dankchat (Kotlin, 30,238).

- **Scope.** chatsen has no EventSub (`rg eventsub` finds nothing), almost no moderation
  (5 matches for "moderat"), and no TTS, analytics, macros, or uploader. Those buckets in
  ours total roughly 13,000 lines with no counterpart.
- **Generated code is not counted.** chatsen uses 47 `part '*.g.dart'` files with zero
  generated lines committed, plus bloc/equatable/Hive and `json_serializable`. We
  hand-write every model and parse.
- **Package and framework reuse.** chatsen uses bloc/cubit, Hive, `cached_network_image`,
  and `chewie`; its whole TMI client is 1,332 lines and its Twitch API 469. We hand-roll
  dual-socket IRC (1,720), EventSub (2,567), a chat kernel (1,587), a custom image/perf
  stack (~1,650), and the connection/ingestion/setup pipeline split.
- **Verbose UI.** About 29,000 lines sit in `screens/` + `widgets/` + `panels/` +
  `sheets/`, versus about 6,000 in chatsen's UI directories.

## Track 1: same behavior, fewer lines

### 1a. Delete dead code (verified, no behavior change)

| Item | Site | Lines | Confidence |
| --- | --- | ---: | --- |
| Dead mod section (`_modTiles`, `_canModerate`, six mod verbs, unused fields/imports) | `lib/sheets/message_menu.dart:75-160,237-350` | ~110 | high |
| `isMention` / `isMentionOf` have no production caller | `lib/util/mention.dart:16,19` | ~13 | high |
| `showModConfirmDialog` never called | `lib/widgets/mod_view.dart:134` | ~25 | high |
| `decodeWebpPureDart` test seam with zero callers | `lib/widgets/emote_image.dart:186` | ~4 | high |

### 1b. Duplication and boilerplate (unify)

| Item | Site | Est. save | Confidence | Risk |
| --- | --- | ---: | --- | --- |
| Shared HTTP/JSON fetch helper across providers | `bttv_emotes.dart`, `ffz_emotes.dart`, `seven_tv_emotes.dart`, `twitch_emotes.dart`, badge services | 30-45 | high | low |
| `_hydrateStashesFromCache` and `_seedMissingStashes` are byte-identical | `emote_manager.dart:1353-1401` | 17-19 | high | low |
| `_isTwitchSub` re-inlined at two sites | `emote_manager.dart:2120-2126,2705-2711` | ~12 | high | low |
| First/single-frame engine decode triplicated | `emote_image_provider.dart:502-540`, `emote_image.dart:467-476` | 20-25 | high | low |
| Two hand-rolled semaphores with identical semantics | `emote_manager.dart:3111-3144`, `emote_image_provider.dart:828-853` | ~25 | high | low |
| 7TV subscribe/unsubscribe pairs | `seven_tv_event_client.dart:241-263` | 18-22 | high | low |
| FPS-pref application duplicated | `emote_applier.dart:76-90,101-116` | ~12 | high | low |
| `command_handler._failureReason` duplicates `mod_actions.failureReason` | `command_handler.dart:105-117` | ~20 | high | low |
| Duplicated date helpers | `mod_view.dart:741-760`, `user_profile_sheet.dart:262-266` | 10-15 | high | low |
| `SettingsSectionHeader` copy-pasted in three screens | `chat_settings_screen.dart:215`, `emotes_settings_screen.dart:652`, `inline_embeds_screen.dart:186` | ~30 | very high | very low |
| Emote-position shift implemented three times | `chat_connection_manager.dart`, `ignore_manager.dart:308-333`, `message_builder.dart:215-218` | 30-40 | medium | low |
| RIFF/WebP chunk walking three times | `emote_image.dart:42-108,414-465` | ~20 | medium | medium |
| Badge-service fetch skeletons | `third_party_badge_service.dart`, `twitch_badge_service.dart` | ~20 | medium | low-medium |
| Duplicate `EmoteType` label/metadata tables | `emote_manager.dart:1145-1157`, `emote_sheet.dart:71-105`, `emotes_settings_screen.dart:76-79` | 15-20 | medium | low |
| GenericEmote field-by-field rebuild (rename site only, fully preserving) | `emote_manager.dart:938-956` | ~20 | high | medium |
| Twitch unlock/override merge predicate four times | `emote_manager.dart:1717-1789,1942-1948` | 20-30 | medium | medium |

### 1c. Redundant layers and extraction candidates (larger)

| Item | Site | Est. save | Confidence | Risk |
| --- | --- | ---: | --- | --- |
| `TwitchApi` clear/send/status/error boilerplate, unify with `_send` | `twitch_api.dart:485-1424` | 250-350 | high | medium |
| `ModActions` resolve-target/guard/run boilerplate | `mod_actions.dart` user and broadcaster verbs | 180-250 | high | medium-low |
| `SettingsNavTile` shared navigation row | `settings_screen.dart`, `tools_settings_screen.dart`, and four more | 70-80 | high | low |
| `confirmDialog` helper | settings screens plus `mod_view.dart` | 130-150 | high | low |
| Reuse the dead `showModConfirmDialog` for six inline confirms | `mod_view.dart:2230,2576,2902,3203,4015` | 60-80 | high | low |
| `showChoiceDialog` radio-list helper | `tts_settings_screen.dart:266-304`, `chat_settings_screen.dart:132-213` | 80-100 | medium-high | medium-low |
| Empty/loading state widgets promoted from `_ModEmpty`/`_ModError` | screens and panels | 30-50 | medium-high | low |
| `mod_view` async load/gen/background/error scaffold, 9 copies | `mod_view.dart` per-tab `_load` bodies | 150-220 | medium-high | medium |
| Prefs facade plus `PrefSwitchTile` | 31 files, 97 `SharedPreferences.getInstance()` calls | 140-200 | medium | medium |
| `PatternRuleFields` shared editor | `pings_screen.dart:451-484`, `ignores_screen.dart:211-260` | 40-60 | medium | medium |
| IRC and EventSub build the same moderation copy | `eventsub_consumer.dart` vs `mod_activity_format.dart:14-85`, `chat_ingestion.dart:303-415` | 50-80 | medium | medium |
| `command_handler` poll/prediction reroute through `ModActions` | `command_handler.dart:901-995,1081-1094` | 20-50 | medium | low-medium |
| `ModActionPrompter` for three mod-action surfaces | `message_menu.dart`, `user_profile_sheet.dart:622-713`, `mod_view.dart` | 60-100 | medium | medium |
| `SettingsCallbacks` value object | `settings_screen.dart:19-123`, `home_screen.dart:1630-1689` | 100-130 | medium | high |

Track 1 realistic total: roughly 2,000 lines, with the low-risk subset (1a plus the
high-confidence rows in 1b) around 500 lines.

## Track 2: replace bespoke with libraries

### Safe (mechanical)

| Area | Size today | Library | Risk |
| --- | --- | --- | --- |
| Sidebar model/DTO serialization | `models/` 828 plus ~71 parse methods across API files | `json_serializable` + `json_annotation`, or `freezed` | none, output equivalent |
| Prefs plumbing | 31 files, 97 `getInstance` calls | `easy_shared_preferences` or a typed facade | low |
| Logging | `util/log.dart` | `logging` | none |
| Time/duration formatting | scattered | `intl`, `timeago` | none |
| Analytics/crash | `analytics_service.dart` 261 plus screen 261 | `sentry_flutter`, `posthog_flutter`, or `firebase_analytics` | low-medium |

### Medium (real wins, needs care)

| Area | Size today | Library | Cost |
| --- | --- | --- | --- |
| HTTP/REST client | `twitch_api.dart` 1488 | `dio` (+ `retrofit` codegen) | preserve `lastError`/`lastErrorStatus` labels and exact status handling |
| Structured persistence | `saved_threads_store.dart` 380, `emote_meta_store.dart`, cache metadata | `drift` or `hive`/`isar` | on-disk migration |
| Settings UI | ~2,468 hand-wired | `settings_ui_plus` plus a typed prefs facade | visual parity, interaction parity |
| Third-party emote clients | BTTV/FFZ/7TV clients ~750 | `dart_7tv`/`dart_bttv`/`dart_ffz`, or `twitch_chat` | vet coverage; parsing drift breaks rendering |

### Do not shift (feature loss or protocol risk)

- IRC transport (1,720) and EventSub (2,567). `tmi`, `twitch_api`, and `twitch_chat`
  exist but do not cover the dual read/write socket, the shared JOIN queue, EventSub v2
  `channel.moderate`, session reconnect, or the points/widgets topics. `twitch_api`
  handles EventSub subscription CRUD only, not receive.
- OAuth (594). The Android Custom Tab flow and multi-account registry are deliberate.
- Chat-state kernel (`lib/chat`, 1,587). Replacing it is an architectural rewrite.
- Emote image/perf stack (~1,650). Exists for the animated-WebP transparency bug and FPS
  governance. `extended_image` would not preserve it.

## Proposed sequence

1. Dead code (1a). Small, zero risk.
2. Low-risk duplication (1b high-confidence rows) and the settings scaffolding helpers.
3. Codegen for serialization plus a prefs facade (Track 2 safe). Largest maintained
   surface reduction.
4. `TwitchApi` `_send` and `ModActions` boilerplate.
5. `dio`/`retrofit` and structured persistence.
6. Settings framework.
7. Vet the emote packages as a spike; adopt only if coverage matches.

## Sources

- Feature budget pass over `lib/`.
- Emote subsystem reduction pass.
- Settings/UI reduction pass.
- Moderation and command reduction pass.
- Library survey (pub.dev), including `settings_ui_plus`, `twitch_api`, `tmi`,
  `twitch_chat`.
