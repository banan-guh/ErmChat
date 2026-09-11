# Behavior checklist

Manual behavior-parity checklist for architecture changes. It gates phases 0 through 5:
every phase ends with these checks unchanged before it is considered done. Visuals must
not change; if a check draws or lays out anything differently, treat it as a failure and
fix the regression. Run through the list on a real device or emulator with a live and a
history-loaded channel, plus an anonymous session.

## Composer and send

- [ ] Typing, cursor, and selection behave as before.
- [ ] Send appends the message and clears the field.
- [ ] Enter and the send button both send.
- [ ] Reply-to and its cancel affordance behave as before.
- [ ] Slash commands route to the right handler.
- [ ] Emote autocomplete and suggestion list behave as before.
- [ ] Cooldown, slow-mode, and self-timeout gating show the same messages.
- [ ] Send rejection notices appear as before.
- [ ] Duplicate-text bypass still works.

## Channel join and leave

- [ ] Add a channel and it joins and joins the stack.
- [ ] Recent-messages backfill loads on join.
- [ ] Join progress and queue position display as before.
- [ ] Part a channel and it disappears from the stack.
- [ ] Switching channels preserves each channel's scroll and state.

## Message ingest

- [ ] Live messages arrive in order.
- [ ] History messages load into the correct channel.
- [ ] Duplicate messages are deduped.
- [ ] Truncation at the message cap keeps the newest messages.
- [ ] Thread replies appear in the thread panel.

## Emotes and badges

- [ ] Twitch, BTTV, FFZ, and 7TV emotes render at the right sizes.
- [ ] Badges render on the right users.
- [ ] Seventh-TV name paints render on usernames.
- [ ] Emote changes refresh spans lazily without a visible rebuild storm.

## Moderation

- [ ] Delete removes the message for mods and users.
- [ ] Ban applies as before.
- [ ] Timeout applies and the timer clears correctly.
- [ ] Warn appears in the feed and activity surfaces.
- [ ] Shield and shoutout behave as before.
- [ ] Automod held messages appear and resolve correctly.

## Whispers

- [ ] Incoming whispers arrive and render.
- [ ] Outgoing whispers send.

## Account switch

- [ ] Switching accounts updates identity and avatar.
- [ ] Token refresh and re-auth behave as before.
- [ ] Anonymous mode clears active credentials and keeps the saved registry.
- [ ] Removing an account leaves the rest intact.

## Settings

- [ ] Chat display settings apply immediately.
- [ ] Theme and accent changes apply immediately.
- [ ] Emote settings apply and persist.
- [ ] Settings survive a restart.

## Scroll and bottom behavior

- [ ] Auto-scroll to bottom on new messages when already at bottom.
- [ ] The jump-to-bottom affordance appears and works.
- [ ] Scrolling up pauses auto-scroll.
- [ ] Bottom state is per channel and survives a switch.

## System and status lines

- [ ] Connection status lines appear and update.
- [ ] Loading-history lines appear and clear.
- [ ] Reconnect and watchdog status surfaces behave as before.

## Panels and threads

- [ ] Mentions, threads, mod, and search panels open and populate.
- [ ] Saved threads load and open.
- [ ] Panel state resets correctly when switching channels.
