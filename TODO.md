# TODO

## High Priority

- [ ] **Check for wasteful rebuilds** - MUCH-NEEDED optimization.
- [ ] **Check for wasteful / unreadable code** - for other people who want to read the codebase.
- [ ] **Token expiry handling** - expired tokens fail silently right now. Validate on startup, catch the login-failed NOTICE, prompt re-auth. Drop unused scopes while at it (%20 -> + too).
- [ ] **Third-party badges** - BTTV donor, FFZ mod/VIP/user, 7TV badges. Fetch + render next to twitch badges.
- [ ] **Emote visibility toggles** - turn each provider (twitch/bttv/ffz/7tv) on/off, gates fetching + sheet.
- [ ] **Phrase muting + regex pings** - hide/block messages matching keywords or regex, word boundary + case options. Lives in tools settings.
- [ ] **Bits / cheermote parsing** - read the `bits` IRC tag on PRIVMSG, parse cheermote tokens (e.g. `Cheer100`) from the body, fetch cheermote metadata via Helix (`/helix/bits/cheermotes`), render tiered animated cheermotes + bit count, and highlight `bitsbadgetier` USERNOTICE.

## Medium Priority

- [ ] **Documentation** - architecture, data flow, key design decisions, non-obvious logic.
- [*] **Update AGENTS.md periodically** - not a checklist, just a chore, reminder.
- [ ] **/warn** - missing manage:warnings scope. Add slash command + long-press menu row.
- [ ] **Poll/prediction broadcaster commands** - /poll /cancelpoll /endpoll /prediction etc. Needs channel:manage:polls + predictions scopes.
- [ ] **Command macros** - local custom commands, {1} {2} {n+} placeholder expansion before send, stored per account.
- [ ] **Join robustness** - unlisted 7TV emote filter; surface suspended / nonexistent channel join failures.
- [ ] **7TV name paints** - animated personal name colors, repaint rows when a paint arrives late.

## Bugs

- [-] **Emotes aren't rendered as text** - when emotes aren't loaded yet, show the emote as text first (0-width not shown as text unless overlapping something), then swap in the image when loaded. Not high-priority but would be nice to fix. (SKIPPED)
- [-] **Invalid argument(s): string is not well-formed UTF-16** - I believe it's a problem with specific characters in the chat messages. Not a crash btw.
- [+] **EventSub emote fragment false-match** - `twitch_eventsub.dart` fragment position parsing used `indexOf` substring search which could misfire when a fragment's text appeared earlier in the message as a substring. Replaced with a running cursor (fragments arrive in order and reconstruct the message). Observed symptom: emote (`vedalSurprise`) rendering as a shorter garbled name (`vedalS`) with leftover text spilling out. Cannot confirm the cursor logic resolves that exact case - if it recurs, add raw fragment payload logging.
- [+] **Add support for twitch widgets** - e.g. hype train, subs, polls

## Research / Open Ends

- [ ] **Send acknowledgement** - verify own messages can't silently vanish if the read socket dies mid-send.
- [-] **Rate limit enforcement** - Enforce the 20-msg / 30-sec limit before Twitch does, with a toggle to disable. Research Twitch's exact rate limit behavior to decide on implementation.
- [+] **WHISPER support** - Route WHISPER into the mentions panel. Needs two authed accounts to verify (anonymous sockets can't receive whispers).
- [-] **Channel point redeems** - (SKIPPED) Redeems only reach IRC when the reward requires viewer text (`custom-reward-id` tag on PRIVMSG; no reward name in IRC). Full visibility needs EventSub `channel.channel_points_custom_reward_redemption.add` + `channel:read:redemptions` scope, or PubSub (DankChat matches PubSub reward payloads to `custom-reward-id`).

## Low Priority / Future

- [+] **OS notifications + background** - background finished, notifs finished for android only, not apple.
- [ ] **Mod View** - official twitch website style. AutoMod queue (hold / approve / deny) as first tab.
- [ ] **Shared Chat depth** - merge participant emotes/badges, spotlight / hide / fade controls. Currently attribution only.
- [ ] **VOD / clip chat replay** - past broadcasts + clips with synced read-only chat.
- [ ] **iOS mention push** - android works, apple server doesn't exist yet.
- [ ] **Notification tuning** - quiet hours, per-channel mutes, sender cooldowns, collapse sub train bursts.
- [ ] **Chat search** - search/filter messages while scrolled up.
- [+] **Slow mode countdown** - countdown on the input box hint, ticks in place; timeouts too (CLEARCHAT ban-duration), mod/vip/sub badges bypass slow.
- [ ] **Emote favorites** - recents exist, favs don't.
- [+] **EXIF strip before upload** - JPEGs re-encoded without metadata before upload, orientation baked in; other formats untouched.
- [ ] **Inline image embeds** - render image links posted in chat, off by default.
- [ ] **Dual-pane view** - read two channels side by side.
- [ ] **Home screen widget / Live Activity** - track last watched channel.
- [ ] **Different mode** - Toggleable type box visibility and fullscreen.
- [ ] **Announcement highlight for remaining USERNOTICE types** - `bitsbadgetier`, `standardpayforward`, `communitypayforward`, `charitydonation`, `modiversary`, etc. render as plain system text with no accent. Deferred until the sub/watch-streak highlight work is pushed.
- [+] **Injectable TwitchBadgeService** - injected like EventSubService/IrcService (TwitchChatApp/HomeScreen params).
- [ ] **AVIF support** - Decode AVIF emotes via libavif + dav1d through the existing FFI shim (`emote_decode_avif`; the shim API is already format-agnostic, see PLAN.md). 7tv uses AVIF so if we can get this to work we can save lots.
- [ ] **Token refresh instead of re-auth every 60 days** - Access tokens expire roughly every 60 days; implement a refresh path instead of forcing full re-auth. Note: implicit-grant tokens (`response_type=token`) can't be refreshed - requires an auth flow change (e.g. device code grant).
- [-] **Make select UI more friendly** - reference dankchat when selecting text. investigate far future.
- [-] **Inkwell on top** - move inkwell of half-under msgs to fully under (currently overlaps). - somewhere it got fixed I think.
- [ ] **Translations** - how?
- [ ] **Accessibility** - make wishlist

## SMALL bugs

- borders flicker white when tabbing in +
- size emote menu better
