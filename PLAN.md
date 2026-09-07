# Localization / i18n

Not yet implemented. No architectural changes required - Flutter l10n is additive and the
codebase's existing patterns (prefs-backed settings state, constructor-injected service
configs) already fit it. Current state: no `intl`, no `flutter_localizations`, no
`l10n.yaml`, no ARB files; `MaterialApp` (main.dart:142,150) has no
`localizationsDelegates`. ~160+ user-facing literals in screens/widgets plus ~50-100 in
services (command usage/error texts, "Connected"/"Disconnected", "Live with X viewers
for Yh Zm", notification titles, loading/error messages) = ~300-400 unique strings.

## L1. Dependency + wiring (small)

- Problem: the app has no localization infrastructure at all, so nothing can be
  translated.
- Solution:
  - Add `flutter_localizations` (SDK) + `intl` to pubspec; create `l10n.yaml` and
    `lib/l10n/app_en.arb` (English is the source locale; other locales start as AI
    translations).
  - Wire `MaterialApp` (both instances in main.dart): `localizationsDelegates:
    AppLocalizations.localizationsDelegates`, `supportedLocales`, and `locale` bound
    to a prefs-backed state field using the existing `_themeMode`/`_setThemeMode`
    pattern (main.dart:103) so the language can switch at runtime.
  - Add a language picker to Settings (prefs key, e.g. `locale`).

## L2. Service access to translations (the one design decision)

- Problem: services build user-facing strings without a BuildContext: `CommandHandler`
  (usage/error texts), `ChatConnectionManager` ("Connected", "Live with X viewers..."),
  `NotificationService` (ping titles), `RecentMessagesService`, `MediaUploader`,
  `foreground_task`. These are composed into system messages rendered in chat, so they
  must be translated at composition time, not at the edge.
- Solution: inject an l10n accessor into services via the existing config-injection
  pattern (`ChatConnectionConfig` already takes ~20 callbacks). A narrow interface,
  e.g. `String Function(String key, {List<Object> args})` (or a `AppLocalizations`
  wrapper), keeps services decoupled from Flutter's localization machinery and is
  trivially testable. Do NOT use a global singleton or leave service strings in
  English.

## L3. String extraction (the big mechanical chunk)

- Problem: ~300-400 hardcoded literals across screens, widgets, and services.
- Solution: replace literals with `AppLocalizations.of(context)!...` keys; use ICU
  placeholders/plurals for dynamic strings ("Live with {viewers} viewers",
  "timed out for {duration}s", "{count} more options"). Order of extraction: settings
  screens -> widgets -> home_screen -> services (via L2).
- Boundary: Twitch's own `system-msg` (sub/raid notices), usernames, emotes, and chat
  text stay untranslated - only app-authored labels translate. Message span/tile
  caches are unaffected (they hold chat content, not labels).

## L4. AI translation workflow + validation (the safety net)

- Problem: AI-generated translations are good for short UI strings but fail
  mechanically on ICU placeholders/plurals (renaming or reordering
  `{placeholders}`), and drift on chat-domain jargon ("emote", "sub", "raid",
  "shoutout", "whispers", "ping") without a glossary.
- Solution:
  - Generate launch locales (de, es, fr, pt, ja recommended; dev/debug screens can
    stay English) with a strict prompt: preserve `{placeholders}` verbatim, keep ARB
    keys and one line per string, obey the glossary.
  - Maintain a glossary of frozen terms: "ErmChat", "emote", "sub", "raid",
    "shoutout", "whispers", "ping", "true dark" - and the intentional placeholder
    strings that must never be translated (e.g. `g;pr[SomgomgAtYou`,
    "glorpKaraoke", foreground_task.dart:67-68).
  - Add a validation test (~50 lines): every ARB parses; every key in `app_en.arb`
    exists in each locale; every `{placeholder}` in the English string exists in the
    translated string (catches the #1 AI failure mode before it ships).
  - Longer translated strings can break layouts (German/CJK) - QA pass per locale;
    RTL languages (ar/he) need a layout pass on the custom tab bar / input row (no
    structural work, Directionality comes from the delegates).

## Verification

`flutter gen-l10n` succeeds; the ARB validation test passes for every locale; app
launches with each locale set; runtime language switch via Settings applies without
restart; services render translated system messages; chat content and Twitch
`system-msg` remain untranslated.

---

# Mod View parity plan (2026-09-07)

Goal: near full parity with the official Twitch app Mod View using only documented
Helix + EventSub + IRC surfaces. No GQL, no scraping, no token sharing.

## A. Audit snapshot (where we are)

Mod View v1 (Tiers 1+2) is done. `TODO.md:47-50` tracks Tier 3 as open.

| Area | Status | Key files |
|---|---|---|
| Shell, 3 tabs Queue/Modes/Mods | Done, needs expansion | `lib/widgets/mod_view.dart:161-238`, `lib/panels/mod_panel.dart:56-73`, `lib/chrome/home_app_bar.dart:84-101` (overflow entry commented out at `:209-220`) |
| Execution layer | Done | `lib/services/mod_actions.dart:29-566` Helix only: timeout/ban/unban/warn/delete/clear, chat settings, shield, mod/vip, announce/shoutout/commercial/raid/marker, automod allow/deny |
| Message menu, user card | Partial | `lib/sheets/message_menu.dart:39-124` (panel variant `:128-157` has zero mod verbs); `lib/widgets/user_profile_sheet.dart:682-805`; opener `lib/sheets/user_sheet.dart:113-284` requires Live at `:148-149` so offline tools hide |
| Slash commands | Done, widest surface | `lib/services/command_handler.dart:273-1128`; only path today for announce/shoutout/commercial/raid/marker/clear/poll/prediction |
| Kernel queue | Done, narrow | `lib/services/chat_store.dart:163-206` `heldMessages` + `heldVersion` only (cap 200, dedupe by id); deletes are `deleted=true` tombstones; no banned roster, warn log, activity list, or structured room state (room tags live in `lib/services/chat_channel_setup.dart:100-101`) |
| EventSub intake | Partial | `channel.moderate` v2 + `automod.message.hold/update` in `chat_channel_setup.dart:384-497`, `twitch_eventsub.dart:537-606`, `chat_connection_manager.dart:1415-1524`. Dropped v2 actions (slow/followers/emote/subs/unique/raid/shoutout/announce/commercial, automod_terms, unban decisions) have no case, and room-mode NOTICEs are suppressed when moderate is active, so mode changes leave no line until the next ROOMSTATE |
| Tier 3 inbox/settings | Missing | Unban inbox, blocked terms manager, warnings log + activity feed, suspicious users + AutoMod settings editor |
| Channel actions UI | Missing UI, verbs exist | Raid/commercial/marker/shoutout/announce/poll/prediction are slash only; viewer cards read-only (`chat_widget_cutout.dart:267,347`) |
| Poll/prediction/raid/commercial as mod via API | Not possible | Broadcaster-match only per Helix auth; keep slash + broadcaster-gated buttons |
| Points | Missing, broadcaster only | See section E |

## B. Gate model

* `isModerationActive(channel)` (existing): `channel.moderate` v2 sub active. Shows mod tools.
* `isBroadcaster(channel)` (new): `session.userId == channelUserId`, same pattern as the hype/poll/prediction widget gate at `chat_channel_setup.dart:510`. Shows the broadcaster-only section, hidden from pure mods with a short hint. Helix 401/403 mapped via `ModActions.failureReason()` stays as backstop.
* Fix: drop the `&& isLive` requirement in `user_sheet.dart:148-149` so offline mod tools work; restore the overflow Mod View entry currently commented out.

## C. Scopes to add (Phase 0, forces re-auth)

Add to `lib/services/twitch_oauth.dart:93-106` and update
`test/unit/auth_services_test.dart:375`:

* Mod: `moderator:manage:blocked_terms`, `moderator:manage:unban_requests`, `moderator:read:warnings`, `moderator:manage:automod_settings`, `moderator:read:chat_settings`, `moderator:read:suspicious_users` (+ manage if editable), `moderator:read:chatters`, `moderator:read:followers`, `user:read:moderated_channels`.
* Broadcaster section: `channel:read:redemptions`, `channel:manage:redemptions` (Points); optionally `channel:read:ads`, `channel:manage:ads` (deferred by default).
* Note: `channel.moderate` v2 subscribes need the read-or-manage set for blocked_terms, chat_settings, unban_requests, banned_users, chat_messages, warnings, plus `moderator:read:moderators` and `moderator:read:vips`, or the sub 403s.

## D. API + EventSub to add

Helix (`lib/services/twitch_api.dart`, wrapped in `lib/services/mod_actions.dart`):

* Mod: `GET/PATCH unban_requests`, `GET/POST/DELETE blocked_terms` (public list only), `GET/PUT automod/settings`, `GET/POST/DELETE suspicious_users`, `GET chat/settings` (read), `GET chatters`, channel followers read, `GET moderated_channels`. Pin/unpin via existing `moderator:manage:chat_messages` scope.
* Broadcaster: `GET bans` (broadcaster-match only), paginated + searchable `getModerators/getVips`, `GET markers`, `GET clips` if wanted, Points verbs `getCustomRewards`, `create/update/deleteCustomReward`, `getRedemptions(UNFULFILLED)`, `updateRedemptionStatus(FULFILLED/CANCELED)`.
* No list endpoint exists for warnings history; build a local append-only log instead.

EventSub (`lib/services/chat_channel_setup.dart`, parse in `lib/services/twitch_eventsub.dart`, handle in `lib/services/chat_connection_manager.dart`):

* Extend the `_emitModeration` switch past ban/timeout/delete/clear/warn/mod/vip: slow/slowoff, followers, emoteonly, subs, uniquechat, raid/unraid, shoutout, announcement, commercial, automod_terms add/remove, unban approve/deny, shared_chat variants.
* Add subs: `channel.ban/unban`, `channel.moderator.add/remove`, `channel.vip.add/remove`, `channel.warning.send/acknowledge`, `channel.chat.clear/clear_user/message_delete`, `channel.chat.notification`, `channel.chat_settings.update`, `channel.shield_mode.begin/end`, `channel.shoutout.create/receive`, `channel.unban_request.create/resolve`, `automod.settings.update`, `automod.terms.update` (public only), `channel.suspicious_user.message/update`.
* Broadcaster only: `custom_reward.add/update/remove`, `redemption.add/update`, `automatic_reward_redemption.add` v1/v2, poll/prediction progress/end (already wired read-only), `channel.raid`, ad break events if ads scope is taken.

## E. Store laws (kernel first per AGENTS.md)

Put rules in `ChatStore`, consume from pipeline/UI. Tests in
`test/unit/chat_store_test.dart`, parsing in `test/data/parsing_test.dart`.

* `ModActivityEntry{at, moderator, action, target, reason, duration}` ring buffer per channel (200 suggested) with `addModActivity` verb; feed emits via `store.events`.
* Per-user `warnLog` (append from `warn` + `warning.send/acknowledge`; no server list).
* Banned/timeout roster with `expires_at` so timeouts can unmark instead of leaving permanent tombstones.
* Keep `heldMessages` semantics (dedupe by id, cap, `heldVersion` bumps); queue rows gain tap-to-profile and inline actions in UI only, not in the kernel.
* Cache `pointRewards` (max 50/channel) + `pointRedemptions` map for the broadcaster tab; enrich thin `.add` payloads from the cache.
* Do not move role sets or room tags into the store unless a second consumer needs them; `ModViewPanel` can keep reading `roomStateTags` + live `getModerators/getVips` with pagination until the feed invalidates them.

## F. UI plan

* Shell: tabs `Queue / Activity / Users / Requests / Terms / Settings` plus a broadcaster-gated section (rosters, polls/predictions management, raid/commercial buttons, Points tab, markers/clips). Queue rows: tap to profile, inline timeout/ban/delete, copy ID, category filter, unread badge, push on new hold.
* Card + menu: panel/history message menu gains mod verbs; add Unban/Untimeout, Clear-user-messages, Shoutout, Mod/VIP toggle to menu and card; card adds Delete-message, follow age, prior record from local logs, shared-ban context from suspicious events. Fix `/slow` int-only vs duration parser and the `/untimeout` "unbanned" copy in `command_handler.dart`.
* Points tab (broadcaster only): rewards list with manageable badge ("created elsewhere: read-only"), redemptions queue with Fulfill/Refund, pause toggle. Pure mods see a hint pointing at `/requests` in the official app. Points needs a monetized channel and only rewards created by our own `client_id` are manageable.
* Polls/predictions: keep viewer cards read-only; broadcaster tab gets create/end/lock/resolve using existing verbs.

## G. TOS boundaries (hard max)

Source: Twitch Developer Services Agreement, ToS xi, forum `21811`.
Only documented `dev.twitch.tv` surfaces. No GQL, no dashboard scraping, no reverse
engineering, no token sharing, respect Helix (~800/min) and EventSub (10k cost cap)
limits, honor `user.authorization.revoke` and keep tokens in secure storage.

* Cannot ship: private blocked terms, permitted-terms CRUD, private-term triggers, Points as mod, managing other-client rewards, full chat history search, `/requests` or dashboard scraping, whisper inbox scraping, mass automation past reasonable volume. These need new public scopes from Twitch.
* Warnings/activity history stays local by design.

## H. Phases + acceptance

* Phase 0 scopes + re-auth notice. Accept: new scope list in code + test, old logins prompted once.
* Phase 1 activity feed + warn log (section D intake + section E store). Accept: every listed v2 action renders an attributed feed row; warns append to per-user log; tests green.
* Phase 2 shell + queue + gates (section B + F shell). Accept: new tabs render, offline mod tools work, queue actions work inline.
* Phase 3 card + menu (section F). Accept: history rows expose mod verbs; unban/untimeout, clear-user, shoutout, mod/vip toggle work from card/menu.
* Phase 4 unban inbox + public blocked terms. Accept: list/approve/deny with resolution text; terms add/remove with public-only note.
* Phase 5 suspicious + AutoMod settings editor. Accept: monitored/restricted lists, evasion signals, per-category 0-4 levels save.
* Phase 6 broadcaster section + Points (sections C broadcaster scopes, D broadcaster verbs, F). Accept: rosters paginated, polls/predictions managed, raid/commercial show cooldowns, Points queue fulfills/refunds own-client rewards and marks others read-only.
* Phase 7 polish: prefs, badges, QA across mod and broadcaster accounts, `flutter analyze`, `flutter test`, format only touched files, update `TODO.md:47-50` + README.







### Emote audit: what actually matters ###
We ran 16 auditors over the whole emote system, then 8 verifiers that threw out false alarms. About 105 issues survived. Here is the readable version.
Critical: emotes show wrong, go missing, or never update
These are the ones users will notice.
Switching 7TV sets leaves the old set on screen
When a streamer switches their active 7TV set from A to B, we subscribe to B but never download B. Channel keeps showing A until restart. Worse, the next refresh can paste A back on top of B.
chat_connection_manager.dart:602-615
FFZ globals include emotes you should not have
We load every set from /v1/set/global but ignore default_sets and the allowlist. So gated effect emotes like ffzRainbow appear for everyone, globally.
ffz_emotes.dart:23-33
FFZ animated emotes always show as static
We check item['animated'] == true, but the real API sends a map or null, never a boolean. So the flag is always false.
ffz_emotes.dart:99
All 7TV emotes marked animated, even static ones
Inside the file loop we set isAnimated = true for any WEBP file. Most 7TV stills are WEBP, so they are all mislabeled. Harmless today because playback sniffs bytes, but the stored data is wrong and any future code that trusts the flag will misbehave.
seven_tv_emotes.dart:169-181
Old Twitch emote wins over the new one in chat
Tag rendering looks up by code: byCode[code] ?? fallback. If the cache has an old Kappa id and the message carries a new Kappa id, we render the old image. Same problem lets a BTTV or 7TV emote with the same code steal a Twitch sub render.
emote_manager.dart:593-600
BTTV animated webp shown as static
We only treat imageType == gif as animated. The API also has a separate animated: true flag, so webp + animated:true is misclassified.
bttv_emotes.dart:85
Usage ranking is broken, favorites get evicted
The 24h histogram always writes to bucket 0 and wipes the prior hour on advance. So entropy is always 0 and the steady-use bonus never builds. Repeat views of the same emote are also ignored after the first one in a session. Net effect: hot emotes look like one-offs and can be evicted first.
emote_manager.dart:118, 3016
Serious: battery, data, hangs, and silent failures
GIFs ignore the FPS cap and Pause
Normal chat GIFs without a cached alternate take the engine path, where _frames stays null. All the throttle code early-returns on null, so cap, pause, and adaptive throttle do nothing for them. Setting Pause still animates.
emote_image_provider.dart:449-455
Chat can hang forever on bad network
Almost all Helix calls have no timeout. Only validateToken has one. If the network stalls, join and moderation calls wait forever. Emote providers do have timeouts, Helix does not.
twitch_api.dart:38-889
Joining many channels fires a request storm
subscribeAll fires all joins at once without waiting. Each channel then fetches the 7TV user twice (once for live setup, once for emotes), plus badges. On a big join this is hundreds of requests and invites 429s.
chat_channel_setup.dart:374, 604-607 + emote_manager.dart:2704-2720
Full cache causes repeat downloads
When the cache is full, every on-screen copy of the same new emote triggers its own HTTP GET. 20 tiles with the same emote means 20 downloads. No in-flight sharing.
emote_cache_manager.dart:294-358
Cap accounting is optimistic
The object count is cached for 1.5s and successful writes do not invalidate it. Bursts inside that window can overshoot the cap. Concurrent writers can also both pass the check before either reserves a slot.
emote_cache_manager.dart:240-256
Thread reply cycle can hang the UI
Truncation walks parentOf chains with no visited set. Two messages pointing at each other as parents loop forever on the UI thread. Needs corrupt or malicious reply ids, unlikely from Twitch directly but possible via history or proxy.
chat_store.dart:819-833
Bad timestamp tag kills a whole batch
tmi-sent-ts uses int.parse. One malformed tag throws and aborts every other line in the same batch because there is no per-line guard.
twitch_irc.dart:722-727
7TV socket leaks on leave and on dispose
Leaving a channel never unsubscribes 7TV, so pending subs grow and we keep getting updates for dead channels. dispose() also nulls the socket before closing it, so close never runs and the timer and subscription leak.
channel_manager.dart:482-504, seven_tv_event_client.dart:695-713
No recovery after reconnect
Reconnect resubscribes but never diffs against REST. Anything added, removed, renamed, or switched while offline stays wrong until restart or rejoin.
seven_tv_event_client.dart:326-336
Medium: visible papercuts
Each of these is one or two sentences.
- Channel fetch timestamp is set before the fetch succeeds, so a failed fetch looks fresh and blocks retry. emote_manager.dart:2064
- Live 7TV add rules disagree with full-fetch rules, so the same code resolves differently depending on arrival path. emote_manager.dart:2394 vs 2565
- Reapplying live 7TV after a fetch can resurrect emotes the fresh fetch just removed. emote_manager.dart:2121-2139
- Empty fetch returns retained stash with no failure signal, so total outages look like success and extend TTL. emote_manager.dart:2646
- Anon Twitch 401 returns empty with no error, so picker is empty but UI says reloaded. twitch_emotes.dart:66-72
- USERNOTICE trim shifts emote indices by the trimmed whitespace, so leading-space subs can lose emotes live but not from history. chat_connection_manager.dart:1277, 1316
- Own sent messages bypass the store ingest verb, so future mention/unread law changes will diverge. chat_ingestion.dart:455-467
- Per-message foreign merge copies and sorts the whole list even though render only needs the map. Mostly hits senders with foreign grants. emote_manager.dart:793-812
- Turning on image embeds disables the span cache for every message, so scrolling re-parses everything. Tradeoff for correctness, but costly. message_builder.dart:72-81
- Toggling fractured-links never invalidates cached spans because the key omits the toggle and the renderer reads a singleton. Old rows stay stale. message_builder.dart:54-60, emote_text.dart:352-355
- Changing OS font size reuses pixel-sized tiles because the tile cache ignores the new scale. chat_view.dart:117-322
- Broken chat images shimmer forever instead of showing the broken icon that panels show. Intentional today, confusing. inline_emote_view.dart:36-387
- Image previews ignore Animate GIFs off and bypass the emote cache. Intentional but contradicts settings text. chat_message_tile.dart:149-177
- WebP decode has no frame count cap and does per-frame work that can jank on huge 7TV anims. emote_image.dart:151-180
- Keyword rewrite shifts emote positions but not GIF positions, so GIFs land in the wrong place after a block replacement. ignore_manager.dart:287-320
- Shared-hide mode starves source emote fetches, so switching back to spotlight shows text until the next foreign message. chat_ingestion.dart:178-186
- Ban-fold edit changes text without bumping the span key, so folded rows can show old spans. chat_store.dart:801-811
- Truncate coalescing uses one global timestamp for all channels, so a hot channel can delay truncation for quiet ones. chat_store.dart:815, 967-984
Low: small bugs and rough edges, grouped
Panels, composer, autocomplete: emote detail appends at end instead of cursor; panel insert ignores selection range, drops focus, can double spaces; mid-word accept merges without space; recents load has no channel guard; open dropdown stays stale across live adds; panel cell cache ignores renames (same id, new code); always-animate needs reopen to take effect; no keyboard selection in dropdown; provider summary flashes all-enabled on open.
Cache details: zero cap can still persist one file via evict-then-write; enforceNow ignores grace and read-protect and can delete mid-read; score-less new emotes always evict even favorites; streaming reads never mark read-protect; read-protect map grows while under cap; full-branch download skips data-usage accounting; failed overflow leaves dead list entry; temp names have no entropy.
Parser details: empty emote id accepted; overlapping ranges mis-slice; lone surrogate off by one; Twitch fallback always dark 3.0; anon room-id 10s timeout aborts silently; Twitch theme picks first-listed not dark; single-scale url3x duplicates url; FFZ owner shows numeric id; FFZ url1x/url3x ignore tier; FFZ hidden ignored; 7TV file order assumed sorted; AVIF-only dropped; accessToken shared across concurrent fetches; tier read late so mixed resolutions in one build.
Models and store details: unknown type silently becomes twitch; unknown scope becomes global; wrong-typed JSON throws TypeError not FormatException; empty id/code accepted; scales accept NaN/negative/zero; tier stored by index so enum reorder breaks cache; aggressive actually fetches less than balanced; meta store swallows all errors, non-atomic write without flush, migrated flag set early, bad keys go memory-only, dir failure sticky, every miss hits SharedPreferences; USERSTATE dropped with no replay; tmi-sent-ts covered above; zombie ping can force-reconnect healthy socket; join limiter completes on send not confirm; notifier never disposed.