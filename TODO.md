# TODO

## Setup

- [x] **Register HTTPS redirect URI** - Go to https://dev.twitch.tv/console/apps and add the `redirectUri` from `lib/twitch_config.dart` to your app's "OAuth Redirect URLs". The URL is a placeholder (`https://example.com/twitch-callback`) and must be replaced with a real HTTPS URL you control (or you can keep the placeholder if you register `https://example.com/twitch-callback` in your Twitch console).

## High Priority

- [x] **Switch to Send Chat Message API** - Replaced IRC-based message sending with `POST /helix/chat/messages`. Added `user:write:chat` scope. Commands like `/color`, `/ban`, `/timeout` now work again via dedicated API endpoints.
- [x] **Emotes & Badges** - Render Twitch emotes (global + channel) as images inline; render badges (mod, sub, VIP, etc). Non-negotiable feature, defer until core is solid.
- [x] **Command autocomplete** - When typing `/` in the input, show a dropdown of available IRC commands (`/ban`, `/timeout`, `/color`, `/me`, etc). MUST HAVE, high priority.
- [x] **IRC command support** - Commands routed through dedicated API endpoints: `/ban`, `/timeout`, `/unban`, `/color`, `/delete`, `/clear`, `/announce`, `/shoutout`. `/me` sent via IRC (only supported IRC command).
- [x] **User profiles** - Tap a username → bottom sheet (1/3 screen) with PFP top-left, display name and account creation date top-right, four buttons: Mention, Whisper, Block, Report.
- [x] **Swipe between channels** - Swipe left/right on the chat area to move to the adjacent channel, in addition to tapping the channel bar.
- [x] **Chat room state** - Display current channel chat status below the input box (e.g. "Followers-only", "Emote-only", "Sub-only", "Live with X viewers for Yh Zm").
- [x] **Thread view input** - Typing box inside the thread view; sending a message auto-replies to the most recent message in the thread.
- [x] **Clickable links** - Detect URLs in chat messages and make them tappable to open in an external browser.
- [x] **Message cutoff** - When a channel exceeds N messages, truncate to N. Keep threads alive until the thread itself passes the threshold. System-level change.
- [ ] **Check for wasteful rebuilds** - MUCH-NEEDED optimization.
- [ ] **Check for wasteful / unreadable code** - for other people who want to read the codebase.

## Medium Priority

- [ ] **Rearrange-ability of channels** - should be able to rearrange where channels are in the top bar
- [ ] **Documentation** - Add comprehensive comments throughout the codebase explaining architecture, data flow, key design decisions, and non-obvious logic (e.g. EventSub vs IRC split, underline animation system, thread panel architecture).
- [x] **/me handling** - `/me` messages detected from `\x01ACTION ... \x01` wrapping in both EventSub and IRC. Rendered as `username message` (no colon, message colored like username) in all 3 views.
- [x] **Unread indicator** - Channel tab name is white when there are unread messages, grey when all are read.
- [x] **Localized display names** - Research how Twitch handles localized/non-ASCII display names and ensure the app handles them correctly.
- [ ] **Add logo / name** - pretty important
- [*] **Update AGENTS.md periodically** - not a checklist, just a chore, reminder.

## Bugs
- [x] **Changing channels should be more smooth** - more leniency in swiping
- [x] **Changing channels is interrupted by new messages** - changing channels is not smooth
- [+] **Threads decay needs to be fixed** - fix implemented, untested
- [x] **Ping happening with system messages** - Ping (unread) should not activate on a system message, currently does.
- [x] **Live color change broken** - color not updating live after /color. Need to test with other people as well.
- [x] **Timeout not showing** - both as system message and 35% opacity message.
- [ ] **Pseudo-timeout not showing** - need to read IRC to see what's happening, IDK what
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

## Research / Open Ends

- [-] **Rate limit enforcement** - Enforce the 20-msg / 30-sec limit before Twitch does, with a toggle to disable. Research Twitch's exact rate limit behavior to decide on implementation.

## Low Priority / Future

- [+] **OS notifications + background** - Push notifications when mentioned/whispered while app is backgrounded; run keepalive in background. - background finished, notifs not
- [ ] **Different mode** - Toggleable type box visibility and fullscreen.
- [ ] **Robotty history bot backup** - Add fallback/backup for recent-messages.robotty.de service.
- [ ] **Injectable TwitchBadgeService** - Currently standalone; consider making it injectable (like EventSubService/IrcService) for testability. Low priority.
- [ ] **Analytics** self-explanatory. just a possible future feature.
- [ ] **Thread customization** - Currently locked into replying to previous user. should allow replying to the first user.