# ermchat architecture

ermchat is a single-package Flutter Twitch chat viewer. `lib/providers` is the composition root: app-scope Riverpod providers construct and dispose the chat kernel (`Chat`), `Session`, the transports, the chat pipeline (`ChatConnectionManager`), the feature owners (`TwitchAuth`, `AnalyticsService`, `ModActions`, `CommandHandler`, `BroadcastWidgets`, and the rest), and the read-state the pipeline consumes. `HomeScreen` is a consumer: it reads providers, forwards UI signals to the presentation owners it still keeps (composer, panels, chrome, message builder, media upload), and drives view-only caches with typed notifiers. Dependencies point inward and downward: raw transports feed decoders, decoders feed pipeline consumers, consumers mutate the `lib/chat/` kernel, and the UI reads kernel state and observes provider-owned objects through `ref.listen`/`ref.watch` or the sanctioned `Listenable` builders. There is no global event bus; each owner exposes a typed notifier or change stream.

Everything below is based on imports, provider wiring in `lib/providers/`, and the `attach()`/`Listenable` registrations in the source. Arrows mean "depends on / feeds". Provider-owned owners are still wired through constructors, but the construction site is a provider, not `HomeScreen`.

## Top-level overview

`lib/` groups into six layers by folder. Arrows mean "imports". Every layer also imports Base, so those edges are left out. The rules for these layers live in `docs/ARCHITECTURE_RULES.md`.

```mermaid
%%{init: {"flowchart": {"nodeSpacing": 50, "rankSpacing": 60, "padding": 12}, "themeVariables": {"fontSize": "16px"}}}%%
flowchart TD
  shell["<b>Shell</b><br/>main, screens, providers"]
  ui["<b>UI</b><br/>chrome, panels, composer, sheets, widgets"]
  app["<b>App services</b><br/>services, channels"]
  kernel["<b>Chat kernel</b><br/>chat, client"]
  transport["<b>Transports</b><br/>irc, eventsub, archive codec"]
  base["<b>Base</b><br/>models, emotes, util, config"]

  shell --> ui
  shell --> app
  shell --> transport
  ui --> app
  ui --> kernel
  app --> kernel
  app --> transport
  kernel ~~~ base
  transport ~~~ base
```

## Known exceptions

The sanctioned departures from the rules, each recorded in `docs/DECISIONS.md`. Keep this list current: add a row when an exception is sanctioned, delete it when the code stops needing it.

| Exception | Where | Why |
|---|---|---|
| widgets import providers | `emote_menu_panel.dart`, `chat_rows.dart` | The emote menu reads the emote and app providers; `ChatRows` reads `chatNoticeProvider` for the copy notice. |
| channels import UI | `channel_manager.dart` | `ChannelManager` takes `ComposerController`, `ThreadPanels`, and `BroadcastWidgets` as constructor deps; `lib/channels` straddles pipeline and UI until its pass. |
| eventsub topics import services and kernel | `eventsub/topics.dart` | `EventSubTopics` is the client surface, not a leaf: it holds `TwitchApi`, `TwitchAuth`, `Chat`, and `Session` to create subscriptions. |
| UI import cycles | panels and composer, widgets and composer | `ComposerBar` opens the mod and search panels and the panels write into `ComposerController`; `ChatBody` hosts `ComposerBar`, which builds on `MessageInput` and `PanelManager`. All one layer. |
| UI notifies the kernel | `home_screen.dart` | `ChannelInfo.touch()` (notify only) after settings that change tile content. |
| HomeScreen owns UI owners | `home_screen.dart` | Composer, panels, chrome, message builder, media upload, panel manager, link whitelist and channel notifier still construct there and use `host: this` ports. |
| `MessageBuilder` stamps tokens | `message_builder.dart` | Memoizes the first-render emote parse onto `TwitchMessage.emoteTokens` for restored threads; one idempotent assignment. |

## Chat data pipeline

```mermaid
%%{init: {"flowchart": {"useMaxWidth": true, "nodeSpacing": 20, "rankSpacing": 30, "padding": 6}, "themeVariables": {"fontSize": "14px"}}}%%
flowchart TD
  read["IrcReadService read socket"]
  write["IrcService write socket"]
  readdec["IrcChatDecoder read"]
  writedec["IrcChatDecoder write"]
  es["EventSubService"]
  esdec["EventSubDecoder"]
  tv["SevenTvEventClient"]

  read --> readdec
  write --> writedec
  es --> esdec
  tv --> tvconsumer["SevenTvConsumer"]

  readdec -->|onMessage / onBan / onDelete / onClear| ingestion["ChatIngestion"]
  readdec -->|onNotice / onJtvMessage / onUserNotice| ingestion
  readdec -->|onWhisper| ingestion
  readdec -->|onOwnMessage| ingestion
  readdec -->|onUserEmoteSets| setup["ChatChannelSetup"]
  readdec -->|onRoomState| lifecycle["ChatLifecycle"]
  writedec -->|onNotice send rejections| ingestion
  writedec -->|onRoomState| lifecycle

  esdec -->|14 typed streams| esconsumer["EventSubConsumer"]
  esdec -->|channel mapping| setup

  ingestion -->|receive / receiveHistory| channel["Channel"]
  ingestion -->|markEmoteViewed / matchEmotes| emoteman["EmoteManager"]
  ingestion --> sender["ChatSender"]
  ingestion -->|pings / ignores / blocks| helpers["PingManager / IgnoreManager / UserStore"]

  setup -->|resolveEmotes / badges| emoteman
  setup -->|setBroadcasterId| info["ChannelInfo"]
  setup -->|ROOMSTATE tags| statuscomp["ChatStatusComposer"]
  setup -->|subscribeChannel| topics["EventSubTopics"]
  setup -->|7TV subscribe| tv

  esconsumer -->|markDeleted / markUserDeleted / markAllDeleted| channel
  esconsumer -->|addFeed / putBan / addHeld| moderation["Moderation"]
  esconsumer -->|setRewards / upsertRedemption| points["Points"]
  esconsumer -->|armTimeout / clearTimeout| sender
  topics -->|createEventSubSubscription| api["TwitchApi"]

  lifecycle -->|connect / reconnect / watchdog| read
  lifecycle -->|connect / reconnect / watchdog| write
  lifecycle -->|connect| es
  lifecycle -->|ensureCurrentUser| api
  lifecycle --> readiness["ChatReadiness"]
  lifecycle --> sender
  sender -->|PRIVMSG| write

  ccm["ChatConnectionManager composition root"] --> lifecycle
  ccm --> ingestion
  ccm --> setup
  ccm --> sender
  ccm --> readiness
  ccm --> topics
  ccm --> esconsumer
  ccm --> tvconsumer
  ccm -->|connectionStateNotifier| home["HomeScreen / composer"]
  ccm -->|connectPhase / remainingSelfTimeout / remainingSlowCooldown| composer["ComposerController"]
  channelmgr -->|upsertSystem| channel

  channel -->|messages.version| home
  channel -->|info.version| home
  channel -->|moderation.modActivityVersion| modpanels["ModPanels / ModView"]
  channel -->|items| builder["MessageBuilder span cache"]
  builder -->|spans| tile["ChatView / ChatMessageTile"]
  home --> body["ChatBody"]
  body --> tile
```

`ChatReadiness` is a pure state holder answering `pipeUp`, `isChannelReady`, and join-failure queries from injected connection predicates. `ChatSender` owns macros, slash dispatch, the duplicate-text bypass, and the self-timeout/slow-mode gates. `ChatStatusComposer` merges ROOMSTATE tags with periodic Helix stream info into `ChannelInfo.status`.

## Emotes

```mermaid
%%{init: {"flowchart": {"useMaxWidth": true, "nodeSpacing": 20, "rankSpacing": 30, "padding": 6}, "themeVariables": {"fontSize": "14px"}}}%%
flowchart TD
  setup["ChatChannelSetup"] -->|resolveEmotes| em["EmoteManager coordinator"]
  ingestion["ChatIngestion"] -->|markEmoteViewed / matchEmotes| em
  applier["EmoteController"] -->|tier / cacheCapMb / reload| em
  applier -->|applyAnimationsEnabled / clearImageCache| render["widgets render ports"]
  home["HomeScreen"] -->|preloadGlobalEmotes| em

  em -->|catalog state / EmoteChange| store["EmoteStore"]
  store -->|addListener| bridge["EmoteStoreNotifier -> emoteStateProvider"]
  bridge -->|ref.listen / select| home
  bridge -->|ref.listen| menu["EmoteMenuPanel"]

  em -->|fetch policy + producers| fetcher["EmoteFetcher"]
  em -->|usage + recents| usage["EmoteUsageRegistry"]
  em -->|personal 7TV sets| personal["SevenTvPersonalSets"]
  em -->|subs + unlocks| twitchsets["TwitchEmoteSets"]
  em -->|catalog persistence| persist["EmotePersistence"]
  em -->|image bytes| images["EmoteImages"]
  em -->|provider visibility| vis["EmoteVisibility"]
  em -->|EmoteLookupSource| lookup["emoteLookupSourceProvider"]

  fetcher -->|fetch| twitchp["TwitchEmoteProvider"]
  fetcher -->|fetch| bttvp["BttvEmoteProvider"]
  fetcher -->|fetch| ffzp["FfzEmoteProvider"]
  fetcher -->|fetch| tvp["SevenTvEmoteProvider"]
  persist -->|file blobs| meta["EmoteMetaStore"]
  usage -->|usage registry| prefs["SharedPreferences"]
  images -->|priorityScore / lastUsedAt| cache["EmoteCacheManager disk repo"]
  cache -->|FileInfo / bytes| imgprovider["EmoteUrlProvider / EmoteImage (widgets)"]
  imgprovider --> emimg["EmoteImage"]
  emimg -->|emote cells| builder["MessageBuilder span cache"]
  imgprovider --> menu
  lookup -->|parse + lookupForSender| builder
  builder -->|buildMessageSpans| tile["ChatMessageTile / ChatView"]

  tvclient["SevenTvEventClient"] --> tvconsumer["SevenTvConsumer"]
  tvconsumer -->|updateSevenTvEmotes / setSevenTvEmoteSetId| em
  tvclient -->|cosmetic / entitlement| tpn["ThirdPartyBadgeService"]
  tvclient -->|entitlement| paint["SevenTvPaintService (widgets)"]
  paint -->|name paint| tile
  tpn -->|badge images| builder
```

`EmoteManager` is the coordinator and single doorway for the emote area, not a daemon: it holds no catalog caches directly. It feeds fetches into `EmoteStore` (plain Dart catalog state: per-scope provider lists, 7TV identity and live sets, merged lookup caches, id index) and coordinates the owners: `EmoteUsageRegistry` (usage plus image eviction policy), `SevenTvPersonalSets` (viewer and foreign personal sets), `TwitchEmoteSets` (subs plus account unlocks), `EmotePersistence` (global/channel catalog blobs), `EmoteImages` (image bytes), and `EmoteVisibility` (provider toggles). `EmoteFetcher` holds the fetch policy and the per-provider producers. `EmoteStore` emits typed `EmoteChange`s; the `EmoteStoreNotifier` bridges that listener stream to `emoteStateProvider`, so widgets observe with `ref.listen`/`select`. The store also owns the canonical emote pool: every served lookup, picker tab, and baked message token holds `identical()` instances per id. `MessageBuilder` reads only the narrow `EmoteLookupSource` (one-shot parse, sender lookup, image owner) exposed by `emoteLookupSourceProvider`. Emote tokens bake onto the message at ingest and freeze; a row baked before its global and channel catalogs landed is flagged `emotesPartial` and only gains emotes on later full commits; live surfaces (typing, picker, menus) read the current mixer on every change. Render-side code (`EmoteUrlProvider` and its animation completer, `EmoteImage`, `SevenTvPaintService`, and decode) lives in `lib/widgets`, and `EmoteController` reaches it through injected ports.

## Moderation

```mermaid
%%{init: {"flowchart": {"useMaxWidth": true, "nodeSpacing": 20, "rankSpacing": 30, "padding": 6}, "themeVariables": {"fontSize": "14px"}}}%%
flowchart TD
  api["TwitchApi createEventSubSubscription"] --> topics["EventSubTopics"]
  es["EventSubService"] --> esdec["EventSubDecoder"]
  esdec --> esconsumer["EventSubConsumer"]
  esconsumer -->|gated by isModerationActive / isFeedActive / isTrustActive / isInboxActive / isPointsActive| mod["Moderation kernel child"]
  esconsumer -->|markDeleted / markUserDeleted / markAllDeleted| msgs["Messages"]
  esconsumer -->|setRewards / upsertRedemption| points["Points"]
  esconsumer -->|armTimeout / clearTimeout| sender["ChatSender"]

  ingestion["ChatIngestion IRC fallback"] -->|markDeleted / markUserDeleted / markAllDeleted| msgs
  ingestion -->|system lines| mod
  mod -->|modActivityVersion / heldVersion / modInboxVersion / modSettingsVersion| panics["ModPanels"]
  panics --> modview["ModView"]
  modview -->|reads bans / warnings / feed / held| mod
  modview --> modactions["ModActions"]
  modactions -->|Helix moderation endpoints| api
  modview -->|formatModActivity| fmt["util/mod_activity_format.dart"]

  command["CommandHandler"] --> modactions
  command --> writer["IrcService slash commands"]
  composer["ComposerBar"] --> command
```

`EventSubTopics` owns the seven topic families (`channel.moderate`, AutoMod, feed, inbox, trust, points, widgets), the per-family active/skip sets, and the account-scoped 403 skip sets. `EventSubConsumer` applies the decoded events; while `channel.moderate` v2 is active it suppresses the duplicate IRC moderation echoes in `ChatIngestion`.

## Auth and accounts

```mermaid
%%{init: {"flowchart": {"useMaxWidth": true, "nodeSpacing": 20, "rankSpacing": 30, "padding": 6}, "themeVariables": {"fontSize": "14px"}}}%%
flowchart TD
  account["AccountScreen"] -->|startFlow| oauth["TwitchOAuth"]
  oauth -->|LoginPresenter| webview["TwitchLoginPage in-app WebView"]
  webview -->|redirect URL| oauth
  account -->|setCredentials / switchTo / switchToAnonymous / removeAccount| auth["TwitchAuth ChangeNotifier"]
  auth -->|accounts registry + active login| secure["FlutterSecureStorage"]
  auth -->|active tokens / login / userId| lifecycle["ChatLifecycle"]
  auth -->|token / login| api["TwitchApi"]
  lifecycle -->|getCurrentUser then setUser| api
  lifecycle -->|apply| session["Session"]
  setup["ChatChannelSetup"] -->|apply| session
  session -->|version| home["HomeScreen"]
  home -->|addListener onAuthChanged| auth
  home -->|reads active token| emoteman["EmoteManager"]
  settings["SettingsScreen"] --> account

  lifecycle -->|accessToken| irc["IrcService / IrcReadService"]
  auth -->|accessToken| topics["EventSubTopics"]
```

`TwitchAuth` is the only owner of credentials (secure-storage registry plus the active account). `Session` is identity only (login/userId plus `version`); it lives outside the kernel, and the pipeline (`ChatLifecycle` and `ChatChannelSetup`) is the only production path that calls `Session.apply`. Anonymous mode clears the active credentials but keeps the saved registry.

## UI and state flow

```mermaid
%%{init: {"flowchart": {"useMaxWidth": true, "nodeSpacing": 20, "rankSpacing": 30, "padding": 6}, "themeVariables": {"fontSize": "14px"}}}%%
flowchart TD
  providers["lib/providers composition root"]
  home["HomeScreen ConsumerState"]
  home -->|owns| caches["_tileCache, _channelNotifier, _atBottomNotifiers, _scrollControllers"]
  home -->|owns| pm["PanelManager overlay + emote sheet"]
  home -->|owns| composer["ComposerController"]
  home -->|owns| managers["ChannelManager, ModPanels, MentionsPanels, ThreadPanels, SearchPanels, HomeAppBar, ChannelPanels, StreamPanels, MessageBuilder, MediaUploadController"]

  providers -->|owns| appscope["Chat, Session, transports, chat pipeline, EmoteManager, EmoteController, TwitchAuth, ConnectivityService, feature owners, read-state"]
  providers -->|selectedChannel / maxMessages / replyTo / blocked / chatReady / macros| home
  session["Session.version"] -->|_onSessionApplied| home
  auth["twitchAuthTickProvider"] -->|ref.listen _onAuthChanged| home
  conn["connectionStateProvider"] --> home
  conn --> composerbar["ComposerBar / HomeAppBar"]
  emotestate["emoteStateProvider (EmoteStore bridge)"] -->|ref.listen _onEmotesChanged| home
  connstate["connectivityTickProvider"] -->|ref.listen _onConnectivityChanged| home
  linkwl["LinkWhitelist ChangeNotifier"] --> home
  stream["StreamPlayerController ChangeNotifier"] --> home

  home -->|_syncChannelSubs| listener["per-channel listeners"]
  listener -->|messages.version| home
  listener -->|info.version| home
  listener -->|moderation.version| home
  listener -->|messages.mutations / addAllListener| home
  mentions["Chat.mentions.version"] --> home

  home -->|setState / markDirty| body["ChatBody"]
  home -->|selected tab notifier| channelstack["ChannelStack / TabbedLayout"]
  home -->|panel requests| pm
  pm -->|activePanel| body
  composer -->|replyTo, suggestions, cooldown| composerbar
  conn -->|connectPhase, remainingSelfTimeout, remainingSlowCooldown| composer
```

Key typed notifiers: `Session.version`, `ChatConnectionManager.connectionStateNotifier`, `Chat.mentionsBump` / `unreadVersion` / `loadFailedChannels`, `Channel.messages.version`, `Channel.messages.mutations` (a synchronous listener set, not a `ValueNotifier`), `Channel.info.version`, `Channel.moderation.version` / `heldVersion` / `modActivityVersion` / `modFeedVersion` / `modInboxVersion` / `modSettingsVersion`, `Channel.points.version`, `EmoteStore.version` (through `emoteStateProvider`), `TwitchBadgeService.version`, `ThirdPartyBadgeService.version`, `LinkWhitelist`, `StreamPlayerController`, `ConnectivityService`, `PanelManager`. View-only caches (tile cache, panel data) stay in `HomeScreen` and are driven by these notifiers. Provider-owned `ChangeNotifier`s (`TwitchAuth`, `ConnectivityService`) and the pipeline's `connectionStateNotifier` are bridged to Riverpod tick providers, while the plain `EmoteStore` listener stream is bridged by `EmoteStoreNotifier` to `emoteStateProvider`, so the shell observes all of them with `ref.listen`; the kernel leaf `Listenable`s remain the one sanctioned direct-observation exception.

## Persistence

```mermaid
%%{init: {"flowchart": {"useMaxWidth": true, "nodeSpacing": 20, "rankSpacing": 30, "padding": 6}, "themeVariables": {"fontSize": "14px"}}}%%
flowchart LR
  prefs["SharedPreferences"]
  secure["FlutterSecureStorage"]
  meta["EmoteMetaStore app docs/emote_meta/*.json"]
  threads["SavedThreadsStore"]
  cache["EmoteCacheManager flutter_cache_manager repo"]
  notif["NotificationService flutter_local_notifications"]

  home["HomeScreen"] -->|channels, settings, prefs, max messages, giphy, accent, theme| prefs
  channelmgr["ChannelManager"] -->|channels list, recent-messages config| prefs
  auth["TwitchAuth"] -->|accounts registry, active login, pending token| secure
  usage["EmoteUsageRegistry"] -->|usage registry| prefs
  persist["EmotePersistence"] -->|global/channel metadata blobs| meta
  images["EmoteImages"] -->|emote image files| cache
  tts["TtsController"] --> prefs
  ping["PingManager"] --> prefs
  ignore["IgnoreManager"] --> prefs
  uploader["MediaUploader"] --> prefs
  stream["StreamPlayerController"] --> prefs
  archivew["ArchiveWriter"] -->|sealed blocks, users, streams, moderation| appfiles["Archive database (SQLite)"]
  threads -->|saved thread metadata + logs| appfiles
  notif -->|mention/whisper local notifications| home
```

## Who writes what

Most arrows in the diagrams are reads or constructor injection, which do not make change hard. Shared mutable state with several writers does, so these are the kernel writes from outside `lib/chat`. Every one calls a public method on the child; none reaches into private state.

| Kernel state | Writer API | Outside-kernel writers |
|---|---|---|
| `ChannelInfo` | `setBroadcasterId` | `ChatChannelSetup`, `EmoteController` |
| `ChannelInfo` | `touch()` (notify only) | `HomeScreen` |
| `Messages` | `markDeleted` / `markUserDeleted` / `markAllDeleted` / `updateText` | `ModerationHub` |
| `Messages` | `removeSystem` | `ChatStatusComposer` |
| `Messages` | `noteHistoryGap` | `ChatHistoryController` |
| `Moderation` | `addFeed` / `addWarning` / `touchInbox` / `touchTerms` / `removeBan` | `ModerationHub` |
| `Moderation` | `addFeed` / `addWarning` / `touchInbox` / `touchTerms` / `touchSettings` / `resolveHeld` / `noteSuspicious` / `removeSuspicious` / `dismissWarningsFor` | `EventSubConsumer` |
| `Moderation` | `noteSubscribed` | `EventSubTopics` |
| `Moderation` | `removeBan` / `removeSuspicious` / `dismissWarningsFor` / `resolveHeld` (after a successful action) | mod view tabs, `UserProfileSheet` |
| `Points` | `setRewards` / `upsertRedemption` / `resolveRedemption` | `EventSubConsumer` |
| `Points` | `resolveRedemption` (after a successful action) | mod view `PointsSection` |
| `Threads` | `pin` / `clearPinned` / `syncSavedKeys` | `ThreadPanels` |

Multi-child writes (`setHistoryLoaded`, `clearHeldModeration`, loading-history rows, system lines) go through `Channel` verbs and are left out.

## Services table

| Component | File | Responsibility |
|---|---|---|
| `ChatConnectionManager` | `lib/services/chat_connection_manager.dart` | Composition root for the chat pipeline; builds and disposes every pipeline owner and exposes phase/readiness/send/gating queries. |
| `ChatLifecycle` | `lib/services/chat_lifecycle.dart` | Connect orchestration, socket status listeners, watchdog, reconnect, token-expiry handling, identity resolution. |
| `ChatIngestion` | `lib/services/chat_ingestion.dart` | Translates IRC PRIVMSG/CLEARMSG/CLEARCHAT/NOTICE/USERNOTICE/own-echo into kernel mutations and feature-sink calls. |
| `ChatChannelSetup` | `lib/services/chat_channel_setup.dart` | Joins, Helix user-id lookup, badge/emote resolution, 7TV subscriptions, and chat-status composition. |
| `ChatSender` | `lib/services/chat_sender.dart` | Outbound send path: macros, slash dispatch, duplicate-text bypass, self-timeout and slow-mode gates. |
| `ChatReadiness` | `lib/services/chat_readiness.dart` | Join-confirmation and read-socket-health state behind readiness queries. |
| `ChatStatusComposer` | `lib/services/chat_status_composer.dart` | Merges ROOMSTATE mode tags and periodic Helix stream info into `ChannelInfo.status`. |
| `JoinRateLimiter` | `lib/irc/join_rate_limiter.dart` | Token bucket pacing the combined JOIN rate of both IRC sockets; fires up to 3 batched lines (18 channels) per tick while the bucket affords it. |
| `EventSubTopics` | `lib/eventsub/topics.dart` | Owns EventSub topic families, active/skip sets, and Helix subscription creation. |
| `EventSubConsumer` | `lib/services/eventsub_consumer.dart` | Applies typed EventSub events to `Moderation`, `Messages`, `Points`, and system lines. |
| `SevenTvConsumer` | `lib/services/seven_tv_consumer.dart` | Applies 7TV socket emote-set/user events to `EmoteManager`. |
| `SevenTvEventClient` | `lib/services/seven_tv_event_client.dart` | 7TV Event API websocket: emote-set, user, cosmetic, entitlement, and personal-set streams. |
| `SevenTvPaintService` | `lib/widgets/seven_tv_paint_service.dart` | Parses and caches 7TV name paints for username rendering (render-side). |
| `EmoteManager` | `lib/services/emote_manager.dart` | Emote coordinator and single doorway: feeds fetches into `EmoteStore`, joins the personal/sub overlays, and orchestrates the owners. |
| `EmoteStore` | `lib/services/emote_store.dart` | Plain-Dart catalog state (per-scope provider lists, 7TV identity and live sets, merged lookups, id index); emits typed `EmoteChange`s. |
| `EmoteFetcher` | `lib/services/emote_fetcher.dart` | Fetch policy and per-provider producers (Twitch/BTTV/FFZ/7TV); returns commits to the store. |
| `EmoteUsageRegistry` | `lib/services/emote_usage_registry.dart` | Usage history and recents; doubles as the image eviction policy. |
| `SevenTvPersonalSets` | `lib/services/seven_tv_personal_sets.dart` | Viewer and foreign 7TV personal set fetch and state. |
| `TwitchEmoteSets` | `lib/services/twitch_emote_sets.dart` | The account's own Twitch emotes from Helix `chat/emotes/user`: subs, follower, bits, plus unlocks (Hype Train, Prime, limited-time). |
| `EmotePersistence` | `lib/services/emote_persistence.dart` | Global/channel catalog read and write as file blobs via `EmoteMetaStore`. |
| `EmoteImages` | `lib/services/emote_images.dart` | Image byte owner: capped disk repo, migration, overflow serving. |
| `EmoteVisibility` | `lib/services/emote_visibility.dart` | Provider enable/disable and unlisted-7TV prefs; mirrored into the store. |
| `EmoteController` | `lib/services/emote_controller.dart` | Applies tier/cache/auto-mode settings, reload, and account-scoped refresh; reaches the render layer through injected ports. |
| `EmoteLookupSource` | `lib/services/emote_lookup_source.dart` | Narrow read-only port the render path consumes: catalog version, sender lookup, image owner. |
| `EmoteCacheManager` | `lib/services/emote_cache_manager.dart` | Disk cap, priority eviction, overflow temp-file serving for emote images; a `flutter_cache_manager` repo, not a singleton. |
| `EmoteMetaStore` | `lib/services/emote_meta_store.dart` | File-backed persistence for MB-scale emote metadata blobs. |
| `EmoteUrlProvider` | `lib/widgets/emote_url_provider.dart` | `ImageProvider` plus the animation `ImageStreamCompleter`; render-side, in the UI layer. |
| `emote_decode` | `lib/widgets/emote_decode.dart` | Pure image decode and format sniffing for emote bytes; render-side, in the UI layer. |
| `TwitchApi` | `lib/services/twitch_api.dart` | Helix REST client: users, streams, badges, moderation, EventSub subscription creation, points. |
| `TwitchAuth` | `lib/services/twitch_auth.dart` | Multi-account registry in secure storage plus the active account credentials. |
| `TwitchOAuth` | `lib/services/twitch_oauth.dart` | OAuth flow (authorize page shown by `TwitchLoginPage`'s in-app WebView), scopes, state validation. |
| `Session` | `lib/client/session.dart` | Active identity (login/userId) with a `version` notifier; identity only, no chat state. |
| `ModActions` | `lib/services/mod_actions.dart` | Helix moderation verbs: ban/timeout, delete, warn, shield, shoutout, terms, points rewards. |
| `CommandHandler` | `lib/services/command_handler.dart` | Slash-command routing to `ModActions`, Helix, and the IRC write socket. |
| `ChannelManager` | `lib/channels/channel_manager.dart` | Channel membership, join/leave, history backfill, selection commit, join-progress system lines. |
| `RecentMessagesService` | `lib/services/recent_messages.dart` | Fetches robotty/zneix recent-message history with provider failover. |
| `Archive` | `lib/services/archive.dart` | The history archive: one lazily opened SQLite `ArchiveStore` with its `ArchiveWriter` (tail per channel, sealed into `lib/archive` blocks) and `ArchiveReader` (windowed reads, search, days). Acts empty if the store cannot open. |
| `ArchiveHistorySource` | `lib/services/archive_history_source.dart` | `HistorySource` over one channel of the archive, feeding `HistoryView`. |
| `SavedThreadsStore` | `lib/services/saved_threads_store.dart` | Archive-database-backed saved-thread metadata and full per-thread message logs. No migration from the old JSON store; memory only if the database cannot open. |
| `PingManager` | `lib/services/ping_manager.dart` | Highlight/mention rules, own-message participation, display-name tracking. |
| `IgnoreManager` | `lib/services/ignore_manager.dart` | Ignored users and keyword block/rewrite rules applied before pings. |
| `LinkWhitelist` | `lib/services/link_whitelist.dart` | Domain/TLD allow list gating link previews and click handling. |
| `TtsController` | `lib/services/tts_controller.dart` | Reads chat messages aloud with queue/format/user-ignore settings. |
| `MediaUploader` | `lib/services/media_uploader.dart` | Uploads pasted/selected media to configured hosts and records recent uploads. |
| `NotificationService` | `lib/services/notification_service.dart` | Local notifications for mention push and whisper alerts. |
| `TwitchBadgeService` | `lib/services/twitch_badge_service.dart` | Global/channel Twitch badge sets, avatars, and broadcaster-id to login mapping. |
| `ThirdPartyBadgeService` | `lib/services/third_party_badge_service.dart` | FFZ/BTTV/7TV badge lookup bound to the 7TV socket. |
| `AnalyticsService` | `lib/services/analytics_service.dart` | Per-channel message and moderation counters with emote usage lookup. |
| `StreamPlayerController` | `lib/services/stream_player_controller.dart` | Stream layout/player state and preferences. |
| `PipService` | `lib/services/pip_service.dart` | Picture-in-picture lifecycle callbacks. |
| `ConnectivityService` | `lib/services/connectivity_service.dart` | Connectivity/wifi-vs-mobile state consumed by transports and emote TTL logic. |
| `MessageBuilder` | `lib/widgets/message_builder.dart` | Builds and caches message spans from baked tokens, keyed on badge/link/gif prefs. |
