# TODO
(x: finished, +: finished, didn't test, -: skip, *: pay attention)

## High Priority

- [ ] **Check for wasteful / unreadable code** - for other people who want to read the codebase.
- [+] **Third-party badges** - BTTV donor, FFZ mod/VIP/user, 7TV badges. Fetch + render next to twitch badges.
- [+] **Emote visibility toggles** - per-provider switches in emotes settings; gates fetching + all rendering (chat, autocomplete, sheet).
- [-] **Bits / cheermote parsing** - parse cheermote tokens (e.g. `Cheer100`) from the body, fetch cheermote metadata via Helix (`/helix/bits/cheermotes`), render tiered animated cheermotes + bit count. Cheer messages already highlight via the `bits` tag (purple banner, live + history).

## Features (competitor survey, Oct 2026)

Picked for a mobile chat client from Chatterino, DankChat, Chatsen, Frosty, Limerino, Xtra, Twire and others.

- [ ] **Emote favorites** - star emotes so they pin to the top of the picker, separate from recents. (Chatterino, Chatty, Limerino)
- [ ] **Haptic / sound on mention in-app** - notifications only fire in the background, so fast chats bury pings while the app is open. Per-highlight sound optional. (Chatterino, Chatty, DankChat, Limerino)
- [ ] **Hide bots and `!command` lines** - filter toggle, big help in busy channels on a small screen.
- [ ] **Local nicknames + user notes** - set from the user card; notes mostly for mods. (Chatterino, Chatty)
- [ ] **Pronouns** - show from the community pronoun service in the user card / chat. (Chatterino, Chatty)
- [+] **Settings search**
- [ ] **Followed + live quick-join** - list followed channels that are live, one tap to join. Helix `streams/followed` with the existing token. Most mobile-native gap; 1.0 headliner candidate.
- [ ] **Link previews** - title + thumbnail cards for links. Opt-in: fetching previews hits the linked site from the user's IP.
- [ ] **In-app changelog** - "What's new" sheet once after an update, reopenable from About. Bundle one changelog file per release (offline, matches the installed build); CI can feed the same text to F-Droid `fastlane/metadata/android/en-US/changelogs`, TestFlight "What to test", Play, and the GitHub release.
- [ ] **Native audio-only stream + background audio** - audio-only today just shrinks the WebView to 1px, which still decodes video and stops when the app backgrounds. Fetch a playback token from Twitch GQL (`PlaybackAccessToken`, web client id), load the usher HLS playlist, and play its `audio_only` rendition through a native player (`just_audio` + `audio_service`: ExoPlayer foreground service on Android, AVPlayer with the iOS background audio mode). Backgrounding a playing stream hands off to it unless PiP auto-enter wins; returning resumes the WebView. Proven by Xtra and streamlink; copy Xtra's token request. Risk: unofficial API, fails safe back to the WebView.
- [ ] **Sleep timer** - pairs with audio-only.
- [ ] **Translations** - see docs/I18N.md. Reach win for F-Droid.
- [ ] **Accessibility** - TalkBack / VoiceOver labels and actions; reduce-motion.
- [ ] **Live notifications for followed channels** - needs background polling on Android and a push server on iOS.
- [ ] **Merged feed** - all channels in one list with channel tags. Niche on a phone.
- [ ] **Dual-pane view** - read two channels side by side (tablets / foldables).
- [ ] **Stream title / category edit** - for streamers using ermchat as a mod tool.

Skipped from the survey: emoji picker (the keyboard has one), follow/unfollow, prediction betting, poll voting, auto-claim (private API only), revealing deleted messages, desktop-only tools (file logging, keyboard mod mode, JSON themes, filter languages), video-app features (VOD downloads, casting, multiview, native quality player).

## Medium Priority

- [ ] **Documentation** - architecture, data flow, key design decisions, non-obvious logic.
- [*] **Update AGENTS.md periodically** - not a checklist, just a chore, reminder.

## Bugs

- [-] **Emotes aren't rendered as text** - when emotes aren't loaded yet, show the emote as text first (0-width not shown as text unless overlapping something), then swap in the image when loaded. Not high-priority but would be nice to fix. (SKIPPED)
- [-] **Invalid argument(s): string is not well-formed UTF-16** - I believe it's a problem with specific characters in the chat messages. Not a crash btw.
- [+] **EventSub emote fragment false-match** - `twitch_eventsub.dart` fragment position parsing used `indexOf` substring search which could misfire when a fragment's text appeared earlier in the message as a substring. Replaced with a running cursor (fragments arrive in order and reconstruct the message). Observed symptom: emote (`vedalSurprise`) rendering as a shorter garbled name (`vedalS`) with leftover text spilling out. Cannot confirm the cursor logic resolves that exact case - if it recurs, add raw fragment payload logging.
- [ ] **Emote errors don't retry** - failed decode/load shows `Icons.broken_image` or stuck band until rebuild. Need to add bounded auto-retry in `_EmoteImageCompleter._load`. Fix before 1.0.
- [+] **Add support for twitch widgets** - e.g. hype train, subs, polls

## Research / Open Ends

- [ ] **Beta channel** - not needed at current user count. When it is: `b<build>` tags go to Play beta + TestFlight + GitHub pre-release; `v<version>` tags only build the GitHub/F-Droid APKs, and stores promote that build by hand. F-Droid's `^v.*$` already ignores `b` tags.
- [ ] **Send acknowledgement** - verify own messages can't silently vanish if the read socket dies mid-send.
- [-] **TestFlight job 500s** - altool sometimes logs 500s on its finalize calls after the IPA is delivered (v0.9.4), so fastlane fails the job even though the build is on ASC. Left as is: the red build email doubles as a "publish manually" reminder, and a re-run would hit a duplicate build number.
- [-] **Rate limit enforcement** - Enforce the 20-msg / 30-sec limit before Twitch does, with a toggle to disable. Research Twitch's exact rate limit behavior to decide on implementation.
- [+] **WHISPER support** - Route WHISPER into the mentions panel. Needs two authed accounts to verify (anonymous sockets can't receive whispers).
- [-] **Channel point redeems** - (SKIPPED) Redeems only reach IRC when the reward requires viewer text (`custom-reward-id` tag on PRIVMSG; no reward name in IRC). Full visibility needs EventSub `channel.channel_points_custom_reward_redemption.add` + `channel:read:redemptions` scope, or PubSub (DankChat matches PubSub reward payloads to `custom-reward-id`).

## Low Priority / Future

- [+] **OS notifications + background** - background finished, notifs finished for android only, not apple.
- [*] **Mod View v1 (Tiers 1+2)** - centralized ModActions service; mod rows in message menu + user card; chat mode toggles; mod/vip lists; AutoMod queue tab.
- [ ] **Mod View: Channel Points reward CRUD** - create/edit/delete UI plus new TwitchApi write verbs (PATCH title/cost, POST create, DELETE). Read-only hardening already landed (cost/age rows, refund confirm, foreign 403 copy, pause notice).
- [+] **Shared Chat** - mirror-only marking, sharedchatnotice unwrap/drop, source-channel emote scoping, lazy participant fetch, ping dedup
- [+] **Spotlight** - global 3-way setting (spotlight/fade/hide) for shared-chat foreign messages; fade dims at 55% opacity, hide drops at ingestion
- [ ] **VOD / clip chat replay** - past broadcasts + clips with synced read-only chat.
- [ ] **iOS mention push** - android works, apple server doesn't exist yet.
- [ ] **Notification tuning** - quiet hours, per-channel mutes, sender cooldowns, collapse sub train bursts.
- [+] **EXIF strip before upload** - JPEGs re-encoded without metadata before upload, orientation baked in; other formats untouched.
- [+] **Inline image embeds** - render image links posted in chat, off by default.
- [ ] **Home screen widget / Live Activity** - track last watched channel.
- [+] **Injectable TwitchBadgeService** - injected like EventSubService/IrcService (TwitchChatApp/HomeScreen params).
- [-] **AVIF support** - 7tv uses AVIF. Skipped: no native decoder in the app and compatibility issues across devices. (for now)
- [-] **Token refresh instead of re-auth every 60 days** - Access tokens expire roughly every 60 days; implement a refresh path instead of forcing full re-auth. Note: implicit-grant tokens (`response_type=token`) can't be refreshed - requires an auth flow change (e.g. device code grant). - too much of a security risk, discard.
- [-] **Make select UI more friendly** - reference dankchat when selecting text. investigate far future.
- [ ] **Configurable user-card history limit** - setting for how many recent messages the user card shows (currently fixed at 50).
- [ ] **Stream player battery saver** - currently streams drink battery like no other. Native audio-only covers part of this.
- [ ] **Extra search feats** - words to filter search
- [ ] **Badge info**
- [ ] **Bug reports via Discord/GitHub login** - replace the report-server flow, which doesn't work.
- [+] **Friendly errors and sign-in retry** - cancelled login needs a restart; errors show codes, not what to do.
- [+] **Highlights row controls** - bell and switch sit side by side with nothing saying which does what.
- [ ] **Channel emote picker layout** - organize channel emotes like the global ones.

## Old backlog (Sep 18, unverified; some may already be fixed)

- [ ] **Emote resilience** - low-res placeholder while the tier goes Low to High.
- [ ] **Visual nits** - tab strip stretch, double Connected on iOS, timestamp gutter width, reply colon on empty preview.
- [ ] **UX consistency** - one slider contract, one empty state, one error with Retry, welcome copy, InkWell audit, More menu Close, macro Save errors.
- [ ] **Races** - notification double-init plus stale map, player and sheet controller swaps, subscribe-then-part.
- [ ] **Mod View triage** - 52 cataloged issues.
- [ ] **Structural (far future)** - split connection/channel/emote managers and mod_view per tab; one tile cache owner and tile config for main, thread, mentions and history; single panel shell.

## SMALL bugs

- borders flicker white when tabbing in -
- notifs don't matter if no foreground in android (ios push notifs, change if server) - DO NOT do, adding server soon
- optimize mod view eventually (currently sweeping it under the rug)
- liquid glass?
- review to see if emote mb cap is robust
- fix sub emotes
- emotes too eager to diff
- integrate ermchat-server better (retry)

- troubleshoot lag on copy
- empty input bar after update?? could not repro, weird bug
- collapse ci test successes

- more friendly err messages
- input bar in threads/glass
- system takes priority rather than user in highlights