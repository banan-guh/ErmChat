# TODO

## Setup

- [x] **Register HTTPS redirect URI** - Go to https://dev.twitch.tv/console/apps and add the `redirectUri` from `lib/twitch_config.dart` to your app's "OAuth Redirect URLs". The URL is a placeholder (`https://example.com/twitch-callback`) and must be replaced with a real HTTPS URL you control (or you can keep the placeholder if you register `https://example.com/twitch-callback` in your Twitch console).

## High Priority

- [x] **Switch to Send Chat Message API** - Replaced IRC-based message sending with `POST /helix/chat/messages`. Added `user:write:chat` scope. Commands like `/color`, `/ban`, `/timeout` now work again via dedicated API endpoints.
- [x] **Emotes & Badges** - Render Twitch emotes (global + channel) as images inline; render badges (mod, sub, VIP, etc). Non-negotiable feature, defer until core is solid.
- [x] **Command autocomplete** - When typing `/` in the input, show a dropdown of available commands. All 41 commands autocomplete for everyone (no mod-permission filter); failed commands surface DankChat-style error notices. MUST HAVE, high priority.
- [x] **IRC command support** - Full DankChat command set routed through dedicated API endpoints: `/ban`, `/timeout`, `/unban`, `/untimeout`, `/color`, `/delete`, `/clear`, `/announce` + color variants, `/mod` `/unmod` `/mods`, `/vip` `/unvip` `/vips`, chat modes `/slow` `/followers` `/emoteonly` `/subscribers` `/r9kbeta` `/uniquechat` + off variants, `/shoutout`, `/raid` `/unraid`, `/shield` `/shieldoff`, `/commercial`, `/marker`, `/w`, `/block` `/unblock`. `/me` sent via IRC (only supported IRC command).
- [x] **User profiles** - Tap a username → bottom sheet (1/3 screen) with PFP top-left, display name and account creation date top-right, four buttons: Mention, Whisper, Block, Report.
- [x] **Swipe between channels** - Swipe left/right on the chat area to move to the adjacent channel, in addition to tapping the channel bar.
- [x] **Chat room state** - Display current channel chat status below the input box (e.g. "Followers-only", "Emote-only", "Sub-only", "Live with X viewers for Yh Zm").
- [x] **Thread view input** - Typing box inside the thread view; sending a message auto-replies to the most recent message in the thread.
- [x] **Clickable links** - Detect URLs in chat messages and make them tappable to open in an external browser.
- [x] **Message cutoff** - When a channel exceeds N messages, truncate to N. Keep threads alive until the thread itself passes the threshold. System-level change.
- [ ] **Check for wasteful rebuilds** - MUCH-NEEDED optimization.
- [ ] **Check for wasteful / unreadable code** - for other people who want to read the codebase.

## Medium Priority

- [x] **Rearrange-ability of channels** - should be able to rearrange where channels are in the top bar
- [ ] **Documentation** - Add comprehensive comments throughout the codebase explaining architecture, data flow, key design decisions, and non-obvious logic (e.g. EventSub vs IRC split, underline animation system, thread panel architecture).
- [x] **"Connected as {user}"** - Account tab in settings currently just says "Connected"; show which account is logged in (e.g. "Connected as {login}").
- [x] **Emote caching in general** - Define an emote caching strategy. ASK before fixing.
- [x] **Fix emote sizing in emote popup** - Emote detail sheet displays some emotes at the wrong size (tall/long emotes clipped or distorted); same class of bug as the fixed chat emote scale issue.
- [x] **24h TTL emote cache** - Cache emotes with a 24-hour TTL; only reload when the user opens the app, and run the refresh in the background.
- [x] **Fetch history when reconnecting** - When the connection is re-established after a drop, re-fetch recent chat history to fill the missed gap.
- [x] **/me handling** - `/me` messages detected from `\x01ACTION ... \x01` wrapping in both EventSub and IRC. Rendered as `username message` (no colon, message colored like username) in all 3 views.
- [x] **Unread indicator** - Channel tab name is white when there are unread messages, grey when all are read.
- [x] **Localized display names** - Research how Twitch handles localized/non-ASCII display names and ensure the app handles them correctly.
- [x] **Add logo / name** - pretty important
- [*] **Update AGENTS.md periodically** - not a checklist, just a chore, reminder.

## Bugs
- [x] **Chat status text never refreshes** - `fetchChatStatus` in `chat_connection_manager.dart` is called once when the channel is subscribed (line 518) but never again. Viewer count, stream duration, and chat room settings (Followers-only, Slow mode, etc.) are frozen at join-time. No periodic timer, no refresh on tab switch, no EventSub stream.online/offline hook. Fix: add a periodic refresh timer or refresh on channel tab switch.
- [x] **Changing channels is interrupted by new messages** - changing channels is not smooth
- [x] **Threads decay needs to be fixed** - fix implemented, untested
- [x] **Ping happening with system messages** - Ping (unread) should not activate on a system message, currently does.
- [x] **Live color change broken** - color not updating live after /color. Need to test with other people as well.
- [x] **Timeout not showing** - both as system message and 35% opacity message.
- [x] **Pseudo-timeout not showing** - need to read IRC to see what's happening, IDK what. FIX: all system messages weren't showing, fixed that already
- [-] **Emotes aren't rendered as text** - when emotes aren't loaded yet, the correct behaviour should show the emote as text first (0-width not shown as text unless they aren't overlapping anything), then replace the text with the emote when loaded. Not high-priority but would be nice to fix. (SKIPPED)
- [x] **IRC fallback creates unreachable pending** - When `_channelUserIds[channel]` is null (e.g. `_subscribeChannel` failed silently), `_doSendMessage` falls through to IRC with a pending entry that has no `_pendingByMessageId` mapping. EventSub can never match it, so the message stays "unconfirmed" permanently. Fix: queue until `broadcasterId` resolves, or skip pending creation when Helix path isn't available. See `home_screen.dart:913`.
- [x] **White highlight of notifications** - If notifications appear (e.g. system messages, whispers, mentions), they light up with white highlight. Not sure what causes this; need to investigate.
- [x] **Fix Twitch emote rendering** - Emotes display incorrectly. Investigate emote parsing, URL generation, or image sizing to get them rendering properly.
- [x] **Fix 7TV system messages** - 7TV emotes/system messages not rendering correctly. Investigate and fix.
- [x] **Twitch emotes don't show in emote menu** - `resolveEmotes` was placed after the `getCurrentUser` gate in `_subscribeChannel`, so if that API call failed the emote fetch was silently skipped. Moved emote resolution before the gate so it always runs when `channelUserId` is available.
- [x] **Twitch emotes not working from emote suggestions** - not showing up
- [x] **Fix bolding** - just a style thing.
- [x] **Fix WCAG** - make similar to other clients, more bright
- [x] **Fix info in settings** - not v0.0.1 anymore
- [x] **Thread close gesture is reversed**
- [x] **@user pings truncate all the time** - non-conditional, should seperate replies from pure @user.
- [x] **Investigate possible malformed API calls** - messages sometimes lag-spike, take maybe 5 seconds to send, sometimes more. This should 100% be looked into, maybe it's API calls and maybe it's something else, IRC loopback problems? who knows.
- [x] **Connect-disconnect spam** - no clue why, it happens too often. CONFIRMED fixed - previous commit.
- [x] **Double connected message** - 2 "Connected" messages on boot - it doesn't really appear anymore? for some reason...
- [x] **Fix emote scale** - some emotes are bigger than they should be and some smaller. mainly happens to "tall" emotes or "long" emotes, square emotes work fine.
- [+] **EventSub emote fragment false-match** - `twitch_eventsub.dart` fragment position parsing used `indexOf` substring search which could misfire when a fragment's text appeared earlier in the message as a substring or overlapped with other text. Replaced with a running cursor (fragments arrive in order and reconstruct the message). Observed symptom: emote (`vedalSurprise`) rendering as a shorter garbled name (`vedalS`) with leftover text spilling out. Fixed the cursor logic but cannot confirm it resolves that exact case - if it recurs, add raw fragment payload logging.
- [-] **Invalid argument(s): string is not well-formed UTF-16** - I believe it's a problem with specific characters in the chat messages. Not a crash btw.
- [+] **Reconnected replacement sometimes misses** - `_addSystemMessage` only checks `msgs.first` for "Disconnected" when "Connected" arrives. If chat messages or subscribe warnings push "Disconnected" down the list, the replacement silently fails and both "Connected" and "Disconnected" stay visible. **Watching but probably fixed**
- [x] **Kill notifications when app is opened** - Mention/whisper notifications should be dismissed when the app comes to the foreground.
- [+] **Add support for twitch widgets** - e.g. hype train, subs, polls
- [x] **Show first time messages** - green
- 

## Research / Open Ends

- [-] **Rate limit enforcement** - Enforce the 20-msg / 30-sec limit before Twitch does, with a toggle to disable. Research Twitch's exact rate limit behavior to decide on implementation.
- [+] **WHISPER support** - IRC `WHISPER` messages are currently dropped entirely, yet the mentions panel empty state claims "mentions or whispers". Route WHISPER into the mentions panel. Needs two authed accounts to verify (anonymous sockets can't receive whispers). Shelved while IRC connectivity work was in progress.

## Low Priority / Future

- [+] **OS notifications + background** - Push notifications when mentioned/whispered while app is backgrounded; run keepalive in background. - background finished, notifs finished for android only, not apple
- [ ] **Different mode** - Toggleable type box visibility and fullscreen.
- [ ] **Robotty history bot backup** - Add fallback/backup for recent-messages.robotty.de service.
- [ ] **Injectable TwitchBadgeService** - Currently standalone; consider making it injectable (like EventSubService/IrcService) for testability. Low priority.
- [x] **Analytics** - Live per-channel chat analytics (total messages, unique chatters, rolling msgs/min, top chatters/emotes/words, bans/timeouts) surfaced via a Settings screen entry; accumulated client-side with no persistence.
- [x] **Thread customization** - Currently locked into replying to previous user. should allow replying to the first user.
- [x] **Add 0-width emotes to popup** - use tab bar menu, small addition
- [x] **Account switcher** - Quickly switch between logged-in Twitch accounts without going through the full login flow each time.
- [ ] **AVIF support** - Decode AVIF emotes via libavif + dav1d through the existing FFI shim (`emote_decode_avif`; the shim API is already format-agnostic, see PLAN.md). 7tv uses AVIF so if we can get this to work we can save lots.
- [ ] **Token refresh instead of re-auth every 60 days** - Access tokens expire roughly every 60 days; implement a refresh path instead of forcing full re-auth. Note: implicit-grant tokens (`response_type=token`) can't be refreshed - requires an auth flow change (e.g. device code grant).
- [x] **Parallelize startup loading** - Increase overall loading speed by running independent startup fetches (emotes, badges, history, chat status) concurrently.
- [x] **Add blocked menu** - `/block` `/unblock` commands implemented; blocked users removed from suggestions/profile. A dedicated un-block UI menu is future work.
- [x] **Fix bug with padding change on keyboard change** - padding changes when keyboard is extended / retracted for some reason
- [ ] **Make select UI more friendly** - reference dankchat when selecting text.
- [-] **Inkwell on top** - move inkwell of half-under msgs to fully under (currently overlaps). - somewhere it got fixed I think
- [ ] **Translations** - how?
- [ ] **Accessibility** - make wishlist
- [x] fade in / out for scroll down


## SMALL bugs
- borders flicker white when tabbing in
- fully transparent emote stops working for some reason X
- size emote menu better
- fix no scope experience X
- fix links parsing X
- fix chat bypass
- add tab bar in analytics X
- ping recent messages to see max msgs
- add reload emotes / reload chat button