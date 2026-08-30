# TODO
(x: finished, +: finished, didn't test, -: skip, *: pay attention)

## High Priority

- [x] **Timeout gate soft block + heal-on-send** - gate no longer hard-blocks; it's a hint in the input box (format "1h 1m 1s"). Cleared on account switch; healed when a sent message echoes back (proves Twitch accepted it); EventSub unban/untimeout clears it for mods. In-memory only, so a restart drops the hint - harmless since Twitch enforces the real block.
- [ ] **Check for wasteful rebuilds** - MUCH-NEEDED optimization.
- [ ] **Check for wasteful / unreadable code** - for other people who want to read the codebase.
- [x] **50-channel hard cap** - `kMaxChannels = 50` in `constants.dart`; `_addChannel` (home_screen.dart:2071) guards new joins past the cap, and the HomeScreen FAB + channel-settings "Join channel" button disable at cap. Restore path (loading saved channels) stays exempt so existing >50 users keep theirs.
- [x] **Token expiry handling** - expired tokens fail silently right now. Validate on startup, catch the login-failed NOTICE, prompt re-auth. Drop unused scopes while at it (%20 -> + too).
- [+] **Third-party badges** - BTTV donor, FFZ mod/VIP/user, 7TV badges. Fetch + render next to twitch badges.
- [+] **Emote visibility toggles** - per-provider switches in emotes settings; gates fetching + all rendering (chat, autocomplete, sheet).
- [x] **Phrase muting + regex pings** - hide/block messages matching keywords or regex, word boundary + case options. Lives in tools settings.
- [-] **Bits / cheermote parsing** - parse cheermote tokens (e.g. `Cheer100`) from the body, fetch cheermote metadata via Helix (`/helix/bits/cheermotes`), render tiered animated cheermotes + bit count. Cheer messages already highlight via the `bits` tag (purple banner, live + history).

## Medium Priority

- [ ] **Documentation** - architecture, data flow, key design decisions, non-obvious logic.
- [*] **Update AGENTS.md periodically** - not a checklist, just a chore, reminder.
- [x] **/warn** - missing manage:warnings scope. Add slash command + long-press menu row.
- [x] **Poll/prediction broadcaster commands** - /poll /cancelpoll /endpoll /prediction etc. Needs channel:manage:polls + predictions scopes.
- [x] **Command macros** - local custom commands, {1} {2} {n+} placeholder expansion before send, stored per account.
- [x] **Join robustness** - unlisted 7TV emote filter; surface suspended / nonexistent channel join failures.
- [x] **7TV name paints** - animated personal name colors, repaint rows when a paint arrives late.
- [x] **un-overlap notifs** - keepalive / push notifs are same panel, split them

## Bugs

- [-] **Emotes aren't rendered as text** - when emotes aren't loaded yet, show the emote as text first (0-width not shown as text unless overlapping something), then swap in the image when loaded. Not high-priority but would be nice to fix. (SKIPPED)
- [-] **Invalid argument(s): string is not well-formed UTF-16** - I believe it's a problem with specific characters in the chat messages. Not a crash btw.
- [+] **EventSub emote fragment false-match** - `twitch_eventsub.dart` fragment position parsing used `indexOf` substring search which could misfire when a fragment's text appeared earlier in the message as a substring. Replaced with a running cursor (fragments arrive in order and reconstruct the message). Observed symptom: emote (`vedalSurprise`) rendering as a shorter garbled name (`vedalS`) with leftover text spilling out. Cannot confirm the cursor logic resolves that exact case - if it recurs, add raw fragment payload logging.
- [ ] **Emote errors don't retry** - failed decode/load shows `Icons.broken_image` or stuck band until rebuild. Need to add bounded auto-retry in `_EmoteImageCompleter._load`.
- [+] **Add support for twitch widgets** - e.g. hype train, subs, polls

## Research / Open Ends

- [ ] **Send acknowledgement** - verify own messages can't silently vanish if the read socket dies mid-send.
- [-] **Rate limit enforcement** - Enforce the 20-msg / 30-sec limit before Twitch does, with a toggle to disable. Research Twitch's exact rate limit behavior to decide on implementation.
- [+] **WHISPER support** - Route WHISPER into the mentions panel. Needs two authed accounts to verify (anonymous sockets can't receive whispers).
- [-] **Channel point redeems** - (SKIPPED) Redeems only reach IRC when the reward requires viewer text (`custom-reward-id` tag on PRIVMSG; no reward name in IRC). Full visibility needs EventSub `channel.channel_points_custom_reward_redemption.add` + `channel:read:redemptions` scope, or PubSub (DankChat matches PubSub reward payloads to `custom-reward-id`).

## Low Priority / Future

- [x] **Add unlimited fps option to emotes** - currently you can only choose a fixed setting, just let it run wild with unlimited
- [+] **OS notifications + background** - background finished, notifs finished for android only, not apple.
- [ ] **Mod View** - official twitch website style. AutoMod queue (hold / approve / deny) as first tab.
- [+] **Shared Chat** - mirror-only marking, sharedchatnotice unwrap/drop, source-channel emote scoping, lazy participant fetch, ping dedup
- [+] **Spotlight** - global 3-way setting (spotlight/fade/hide) for shared-chat foreign messages; fade dims at 55% opacity, hide drops at ingestion
- [ ] **VOD / clip chat replay** - past broadcasts + clips with synced read-only chat.
- [ ] **iOS mention push** - android works, apple server doesn't exist yet.
- [ ] **Notification tuning** - quiet hours, per-channel mutes, sender cooldowns, collapse sub train bursts.
- [ ] **Chat search** - search/filter messages while scrolled up.
- [x] **Slow mode countdown** - countdown on the input box hint, ticks in place; timeouts too (CLEARCHAT ban-duration), mod/vip/sub badges bypass slow.
- [-] **Emote favorites** - recents exist, favs don't.
- [+] **EXIF strip before upload** - JPEGs re-encoded without metadata before upload, orientation baked in; other formats untouched.
- [ ] **Inline image embeds** - render image links posted in chat, off by default.
- [ ] **Dual-pane view** - read two channels side by side.
- [ ] **Home screen widget / Live Activity** - track last watched channel.
- [x] **Different mode** - Toggleable type box visibility and fullscreen.
- [x] **Announcement highlight for remaining USERNOTICE types** - `standardpayforward`, `communitypayforward`, `charitydonation`, `modiversary`, etc. now highlight like the subs: every USERNOTICE label carries an accent (announcements use their banner color, everything else PRIMARY purple) via `userNoticeAccent`.
- [+] **Injectable TwitchBadgeService** - injected like EventSubService/IrcService (TwitchChatApp/HomeScreen params).
- [ ] **AVIF support** - Decode AVIF emotes via libavif + dav1d through the existing FFI shim (`emote_decode_avif`; the shim API is already format-agnostic, see PLAN.md). 7tv uses AVIF so if we can get this to work we can save lots. <- Most likely not happening, compatibility issues across devices with shims.
- [-] **Token refresh instead of re-auth every 60 days** - Access tokens expire roughly every 60 days; implement a refresh path instead of forcing full re-auth. Note: implicit-grant tokens (`response_type=token`) can't be refreshed - requires an auth flow change (e.g. device code grant). - too much of a security risk, discard.
- [-] **Make select UI more friendly** - reference dankchat when selecting text. investigate far future.
- [-] **Inkwell on top** - move inkwell of half-under msgs to fully under (currently overlaps). - somewhere it got fixed I think.
- [ ] **Translations** - how? - l110 or whatever it's called i dont remember
- [ ] **Accessibility** - make wishlist

## SMALL bugs

- [x] **Scroll-to-bottom FAB sticks after channel switch** - `atBottomNotifier` isn't reset when the `FlutterListView` rebuilds with a new channel key. `ScrollEndNotification` handler partially fixes it (fling settling at bottom), but switching away and back still shows a stale FAB. Need to invalidate `atBottomNotifier` on channel change upstream in `HomeScreen`.
- borders flicker white when tabbing in
- size emote menu better
- dedup spaces in reply string X
- style bug, add stretch for tab bar channels
- notifs don't matter if no foreground in android (ios push notifs, change if server)