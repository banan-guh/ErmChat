# History archive

Spec for persistent chat history: a local archive of every message the app receives,
scrollable back up to a month, with stream markers, a stream map, and VOD replay.
Status: in progress, see Progress. Ships as a version bump.

## Progress

Done:

- Prototype windowed list on generated data: go (60 fps on device). Markers, scrubber
  rail, rail jumps clamp at both ends.
- Block codec (`lib/archive/`), SQLite storage, writer, reader, retention, cold start
  restore before robotty. Always on: every install archives now.
- Live stream rows (announcement layout, purple tint), deduped by Helix stream id.
- History parsing in an isolate; join timeout with "Couldn't join, retrying".
- Saved threads live in the archive database (see Saved threads).

Next, in order:

1. Windowed list reads the archive instead of generated data, then replaces ChatView
   scrolling.
2. Streams screen.
3. VOD view.
4. Memory diet, ids dropped after 24h.

Loose ends are tracked in TODO.md under "History archive". Do not tag a release while
the archive is on but the list cannot read it.

## Goals

- Scroll back through past chat in one continuous list, with no pages.
- Jump to any day or stream in a few gestures, without permanent buttons on screen.
- Keep cold start fast: on iOS the app is killed constantly, so launch restores from
  disk and only fills the gap from the network.
- Keep disk and memory small enough for 20 joined channels.

Non-goals for v1: a server archive (later, see Open questions), search, semantic zoom.

## Pieces

| Piece | Summary |
|---|---|
| Archive | Compressed blocks of about 256 messages per channel in SQLite, plus user tables. |
| Retention | Rolling 30 days. Pinned days and saved threads are kept forever. |
| Cold start | Restore the newest window per channel from disk, then fill the gap from robotty. |
| Windowed list | One scroll view over a sliding window of decoded rows, re-anchored as you move. |
| System messages | Clickable stream started/ended rows and day markers past 24h. |
| Scrubber | Time rail that appears after scrolling about 500 messages up. |
| Streams screen | One card per stream with a chat activity waveform you can scrub. |
| VOD view | Twitch embed with `video=`, chat replayed from the archive. |

## Archive format

Measured on 4,477 real messages from six busy channels (robotty, October 2026):

| Layout | Bytes per message |
|---|---|
| Raw IRC line | 468 |
| Raw lines in 256-message zlib blocks | 120 |
| Columnar, all tags, zlib | 80 |
| Columnar, junk dropped, time deltas, binary ids | 70 |
| Target schema below | about 25, plus 16 for an id inside 24h |

Per-message cost by tag (compressed): `id` 21.5, `client-nonce` 14.7, text 12.8,
`display-name` 4.5, `tmi-sent-ts` 3.6, `rm-received-ts` 3.6, `user-id` 3.2, `badges`
2.9, `emotes` 1.8, reply tags about 5.

Rules:

- Compress blocks, never single messages: a lone message compresses larger than raw.
- zlib from `dart:io`. zstd measured 5x faster to decompress but block decode is
  dominated by building objects, and zlib needs no native dependency.
- Columnar inside a block: one stream per field, each varint or dictionary coded.
- Time: one timestamp per message as a varint delta from the previous one.
- Ids: Twitch message ids are kept for 24 hours (the Helix delete window is 6 hours,
  replies to older parents were not seen in samples: median parent age 18s, max 64
  minutes). After 24 hours an id is dropped unless a reply references it; referenced
  ids live in a side table.
- Dropped entirely: `client-nonce` (nothing reads it), robotty's duplicate
  `rm-received-ts`, the reply's copy of the parent body when the parent is archived.
- Tags: a presence bitmask over known keys, boolean tags as bits (`first-msg`, `mod`,
  `subscriber`, `vip`, `turbo`, `returning-chatter`), repeated values (badge combos,
  `msg-id`, colors) as dictionary numbers, plus a catch-all key=value column so unknown
  tags are never lost.
- Emote tokens are stored as emote id references with positions, so a restore maps ids
  to the cached catalog instead of re-tokenizing text.
- User state lives in tables, not in messages (see User state).

## User state

- **Who**: user id, login, display name. One row per user, written once.
- **Look**: color, badge combo, 7TV paint, third-party badges. Interned by value, so
  every user with the same look shares one row.
- A message references a `UserState` (who plus look) by one pointer in memory (4 bytes)
  and a varint on disk (usually 1 byte). A new look row is written only when a user's
  look changes, so history shows what was true at the time.

## Storage engine

- SQLite with WAL, so a kill mid-write loses at most the last unsynced batch.
- Tables: `blocks(channel, start_ts, end_ts, count, data BLOB)` keyed for time seeks,
  `users`, `looks`, `ref_ids` (referenced message ids), `streams` (stream id, channel,
  started_at, ended_at, title, game, vod id), `minute_counts(channel, minute, count)`
  for the scrubber and waveforms, `pins` (pinned days), and the saved thread tables
  (`saved_threads`, `thread_messages`, `meta`).
- Package: see Open questions.

## Writes and kill safety

- New messages append to an in-memory tail and are sealed into a block every 256
  messages or 30 seconds, written in one transaction (batched).
- Nothing waits for a lifecycle event: iOS kills backgrounded apps without warning.
- Writes run off the UI isolate.

## Retention

- Rolling 30 days per channel.
- A day can be pinned (kept forever). Saved threads are kept forever in their own tables.
- Optional later: strip rows older than N days down to text, time, user and reply links
  (about 30% smaller). Not in v1.
- Expected size at 32 bytes per message: a busy channel (100k messages a day) is about
  3 MB a day, about 90 MB per 30 days. Typical channels are a fraction of that.

## Cold start and prefill

Target: the selected channel's chat is visible within 300 ms of a cold start, and the
rest fills in without dropping a frame. Measured through `PerfLog`.

1. Read the newest window per channel from the archive. Decode in one background
   isolate and hand results over with `Isolate.exit` (no copy).
2. The selected channel decodes first (newest 50 rows, then the rest), then the other
   channels.
3. Fill the gap since the last archived message from robotty (at most about 800
   messages) and dedup against the restored rows by id. A gap larger than robotty can
   fill gets a "not recorded" row.
4. First launch (empty archive) uses the network path. History parsing for a batch of
   at least 200 lines runs in an isolate; smaller batches parse inline.

## Windowed list

The highest-risk piece. Prototyped first (see Prototype).

- One scroll view. The data is a sliding window of a few thousand decoded rows over the
  archive. Blocks load at the edge you approach and drop from the far edge.
- The message limit setting becomes the size of the live window in memory; history
  depth is set by retention.
- Live chat is the newest window. Scrolling past its top continues into the archive
  with no mode switch.
- Loading older rows is free: the list is reversed, so older rows attach at the far end.
- Dropping rows on the near side would shift the scroll position, so the list keeps an
  anchor (`CustomScrollView` with a `center` key). Deep in history the anchor moves to
  the row on screen and the position is corrected with `ScrollPosition.correctBy`,
  which keeps an active fling alive. Then the far side can be trimmed freely.
- A jump (scrubber, system message, reply parent) sets the anchor at the target time
  and loads blocks on both sides.
- Compressed blocks around every jump point (each day marker and stream start) stay in
  memory, about 6 KB each, about 4 MB for 20 channels over 30 days. Decoding one takes
  under 1 ms. Scrubber and waveform drags prefetch the landing block.
- Must not regress the `ChatView` crash guards (flutter#153922, slot-limited
  `findChildIndexCallback`).

## System messages

Clickable, colored system rows. No dividers, no buttons.

- **Stream started**: "Stream started . title . game". One per Helix stream `id`
  ("You can use this ID later to look up the video on demand"), so polls, reconnects
  and restarts never duplicate it. Start time from `started_at`.
- **Stream ended**: "Stream ended . 3h12m". End time from the first poll that sees the
  stream offline, corrected later from the VOD duration.
- Source: the existing 30 s `getStreams` poll, which already returns `id` and
  `started_at`. Helix needs login, so anonymous users get day markers only.
- **Day marker**: only for history older than 24 hours, attached to the first message
  of a new day (never at midnight itself), so empty days produce none.
- **Empty stretch**: consecutive days without messages collapse into one row,
  "Oct 3 to Oct 7 . nothing recorded".
- **Gap**: "Not recorded 02:10 to 09:40" where the app was not connected.
- Tapping a stream message opens the Streams screen at that card. Tapping a day marker
  shows the scrubber at that day.

## Scrubber

- Appears after scrolling about 500 messages up, or after a hard fling. Fades after
  about 1.5 s idle. Never permanent.
- The rail maps time over the retained month, weighted by activity: offline hours
  shrink, streams get most of the length.
- Dragging shows a bubble ("Tue Oct 13 . stream title . 21:40") and gives a haptic tick
  at each day and stream boundary. Gaps show as hollow rail sections.
- The rail picks the stretch; the finger does fine scrolling.

## Streams screen

- One card per stream: title, game, date, length, VOD thumbnail when a VOD exists, and
  a waveform of chat messages per minute across the card width.
- Dragging along the waveform moves a playhead, shows the chat lines at that moment in
  a small preview, and ticks on peaks. Releasing jumps chat there.
- A play control opens the VOD at the playhead with chat replay.
- Expired VODs say so; their chat still works.
- Entry points: tapping a stream system message, or tapping the scrubber bubble.

## VOD view

- Video: the existing embed with `player.twitch.tv/?video=v<id>&time=...&parent=twitch.tv`.
  Position from the `<video>` element's `timeupdate` through the existing JavaScript
  channel; seek by setting `currentTime`.
- VOD lookup: Helix Get Videos (`type=archive`), matched to a stream by `stream_id`.
- Chat replay comes only from the archive: the message at playback time `t` is the one
  stamped `created_at + t`. Twitch's own replay is only reachable through undocumented
  GQL, which the Developer Agreement forbids.
- A small sync nudge corrects stream delay drift. Gaps show as gap rows.
- Sub-only VODs need the matching login in the WebView (per-account WebView profiles).

## Saved threads

- Stored in the archive database (schema version 2): `saved_threads` (one bookmark row
  per thread), `thread_messages` (one row per message, `TwitchMessage.toJson` as bytes),
  and `meta`. A thread can outlive retention and span many days, so these tables are
  separate from blocks and retention never touches them. The 50-thread cap evicts the
  oldest saved.
- Save, unsave and eviction write at once in a transaction. A new reply queues one row;
  queued rows flush in one transaction within 1 s of the first change (later changes
  join the timer) and on app pause. A crash loses at most the unflushed rows.
- Load reads the rows and decodes off the UI isolate when large. Saves made during load
  merge into the loaded list.
- Migration, once, at load: `saved_threads/index.json` and every thread file (falling
  back to `.bak`, then the older prefs snapshot) are imported in one transaction that
  also sets the `meta` marker `saved_threads_json_migrated`. Unreadable thread files are
  logged and skipped; an unreadable index is left alone and retried. The files stay for
  one launch; the next launch with the marker deletes the directory.
- If the database cannot open, the JSON files are read into memory and nothing persists
  that session; the files are untouched, so the import runs once the database opens.

## Memory diet for `TwitchMessage`

Current estimate about 0.9 to 1 KB per row; target 350 to 450 bytes.

- Pack the eight bools into one flags int.
- Timestamp as epoch ms `int` instead of `DateTime`.
- Replace `login`, `displayName`, `color`, `userId`, `badges` with one `UserState`
  pointer.
- Intern channel, thread root ids.
- Drop `EmoteToken.text` and `EmotePosition.emoteCode` (derivable from the text).
- Move rare fields (rewards, bits, paid amount, source ids, gifs, reply fields) into an
  optional extras object.

## Prototype

Debug and profile builds only, never release. Data is generated procedurally from the row index,
never stored, so millions of rows cost no memory.

- `_testchannel`: "testuser: testing" every 10 minutes for a month, plus a few fake
  streams. Checks system messages, day markers, empty stretches.
- `_testdense`: about 2 messages a second for a month (about 5M rows), varied lengths
  and replies. Checks flings, re-anchoring, jumps, and cold start time.
- Neither name may reach IRC.

## Phases

1. Prototype the windowed list on generated data. Go or no-go.
2. Archive: block codec, storage, writes, retention, cold start restore with gap fill.
3. System messages, scrubber, Streams screen.
4. VOD view.
5. Memory diet.

Independent of all phases: per-account WebView profiles.

## Open questions

- SQLite package: decided `sqflite` (platform SQLite, no bundled binary, F-Droid safe).
  Revisit `sqlite3` only if platform-channel cost shows up in profiles.
- Lazy tokenizing: stored token references remove most of the need; the user has
  concerns to share.
- Server archive (ermchat-server): per channel, not per user, with a rolling window.
- Strip-by-age for rows older than N days.
