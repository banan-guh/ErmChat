# ErmChat

A mobile Twitch chat app built with Flutter.

ErmChat is a DankChat-inspired chat client with more features, built for multi-platform. If you've had experience with other chat clients, this one is similar with some fun features stapled onto it, and a bit less polish. I made this because Chatsen didn't have the "feel" I liked, and I wanted a good alternative to it on iOS.

Credit to NobleTrash38 / NobleTrash for inspiring this project!

Check [TODO.md](TODO.md) for the roadmap. Found a bug or want a feature? Open an issue or submit a PR (see [RULES.md](RULES.md) first for commit style and ground rules).

## Features

**Chat**
- Tabbed multi-channel chat with swipeable views and rearrangeable channel bar
- Multi-account login with a switcher in settings
- Messages over IRC
- Reply threads with inline view (threads persist until last child goes over max msg threshold!! even when they disappear, you can see old threads)
- Mentions / whispers panel
- User profiles: tap a username for a bottom sheet with Mention / Whisper / Block / Report
- System messages for subs, cheers, raids, bans, timeouts, announcements (subs/bits/raids highlight with the accent)
- Shared chat support with spotlight / fade / hide modes for foreign messages
- Phrase muting and regex ping rules (hide or highlight by keyword)
- Slow-mode countdown on the input hint
- Chat room state below the input (followers-only, emote-only, sub-only, live viewer #)
- Clickable links, message timestamps with customizable formats
- Configurable message cutoff and recent-history limit
- Unread indicators, `/me` actions, message bypass for spam

**Emotes & badges**
- Emotes from Twitch, BTTV, FFZ, and 7TV with zero-width overlay support
- Per-provider emote visibility toggles
- Badges for mods, VIPs, subscribers, plus 3rd party badges (BTTV donor, FFZ mod/VIP, 7TV)
- 7TV animated username paints rendered in chat
- Emote and username autocomplete
- Emote menu with provider tabs and a detail sheet (copy / share)
- 7TV live emote updates via WebSocket

**Commands**
- 41 slash commands routed through the Twitch Helix API: `/ban`, `/timeout`, `/unban`, `/untimeout`, `/color`, `/delete`, `/clear`, `/announce` + color variants, `/mod`, `/vip`, chat modes (`/slow`, `/followers`, `/emoteonly`, `/subscribers`, `/r9kbeta`, `/uniquechat` + off variants), `/shoutout`, `/raid`, `/shield`, `/commercial`, `/marker`, `/w`, `/block`, `/unblock`, and more
- `/` autocomplete for every command (permissions checked server-side)
- Command macros with `{1} {2} {n+}` placeholder expansion, stored per account
- DankChat-style error notices for failures

**Broadcaster widgets**
- Hype train, poll, and prediction cards rendered in a swipeable cutout above chat (for the broadcaster's own channels, read-only)

**Customization & settings**
- Dark mode toggle, true-dark, accent color picker
- Timestamp format picker, keep-screen-on, custom ping highlights
- Per-channel chat analytics (total messages, unique chatters, msgs/min, top chatters/emotes/words, bans/timeouts)
- Background keepalive and mention push notifications (Android ONLY! iOS is still unpolished)
- EXIF metadata stripped from image uploads before they go out
- "Connected as {login}" account display, paste-token or browser OAuth login

## Getting started (for people who clone the repo for their own use)

1. Clone with submodules (the native WebP decoder is a pinned libwebp submodule at
   `third_party/libwebp`, built from source - no prebuilt binaries, no extra downloads):
   `git clone --recursive <repo-url>` (or `git submodule update --init` in an existing checkout).
2. Create a Twitch app at https://dev.twitch.tv/console/apps and get a client ID.
3. Open `lib/twitch_config.dart` and put it there.
4. NOTE: redirect URI from `lib/twitch_config.dart` must match EXACTLY with what's in your twitch dev console. even / count.
5. Android: JDK 17, 21, or 26 all work (CI uses Zulu 17), plus the standard
   Android NDK, then run the app:
   `flutter run`
6. iOS: install pods first (the podspec compiles libwebp from the submodule too):
   `pod install` inside `ios/`, then `flutter run`

`flutter test` and `flutter analyze` need no extra setup. The optional host-side native
build (`tool/build_native_linux.sh`) is only for the gated native-codec tests.

## Note for what the fastlane folder is

It's just for the F-droid publication. if you want to clone this and put it on F-droid, you need the changelogs folder to have these txt files:
10[].txt
20[].txt
40[].txt

(the [] is the "+N" you have in pubspec, e.g. v0.5.8+14). Make sure you update this along with pubspec every update you push.
You can delete old changelogs, they aren't necessary to keep around. Reason for 3 different changelogs is just the split-ABI structure.

## License

MIT
