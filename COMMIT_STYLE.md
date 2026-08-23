# Commit style

Derived from the actual log (350+ commits). Match the recent norm, not the messy early history.

## Subject line

```
<type>: <lowercase summary>[, <second change>]
```

- Types, in order of frequency: `fix`, `refactor`, `feat`, `chore`, `style`, `perf`, `ci`. One type per commit; pick the dominant one.
- No scopes (`feat(emotes):` never happens), no ticket refs, no trailing period.
- Imperative present tense: `add`, `fix`, `merge`, not `added`/`fixes`.
- Lowercase first word after the type.
- Multiple unrelated-ish changes in one commit: comma-separate them instead of writing "and various fixes".
  - `fix event highlighting, update todo`
  - `feat: add media upload, reload, reorganize settings`
- Length: under 50 characters if possible, hard cap below 65. Short forms win (`notifs`, `prefs`, `ui`, `3rd party`). No filler (`various`, `some`, `support for`, `cleanup of`).
- Top-down language: say what the change is FOR (the outcome), not what you mechanically did. No line numbers, no raw identifiers, no file-by-file narration in the title.
- NEVER write a subject so long it gets cut off mid-word in log views (`git log --oneline`, PR lists, terminal width, whatever). A title that renders like `this message cu` / `ts off` is a bad commit message, do not do this. The comma-list convention above is for SHORT lists only; past the length cap, drop detail into body bullets instead.

### Good vs bad

- `feat: ping rules` NOT `feat: ping rule engine - regex keywords, user/badge highlights, blacklist, per-rule notifications`
- `refactor: emote picker into sheet` NOT `refactor: providers move to bottom sheet, twitch always on - picker tile sits at the bottom of the emotes settings page - checkboxes in a modal...`
- `fix: token refresh races oauth callback` NOT `fix: serialize storage queue via async semaphore in twitch_auth.dart`
- `fix: recents filled bad aliases` NOT `fix: correct stale alias resolution order in EmoteManager.recentCodes rebuild path`

## Parenthetical asides

Append `(context)` to the subject for caveats, scope limits, or pointers:

- `fix (attempt): oauth smooth out`
- `feat: added twitch overlay (ONLY for self) - twitch limitation, ToS`
- `c8e1923 full audit / correctness / bugs rewrite (look at PLAN.md)`
- `a64844c refactor: merge tests into less files (tired of file change bloat)`

Pointers to docs are fair game: `(look at PLAN.md)`, `check PLAN.md`.

## Body (optional, use for anything non-obvious)

- Default is NO body. Only add one for a genuinely big/risky commit whose why isn't guessable from the title+diff, then 2-4 terse bullets max. If the title says enough, stop typing. KISS.
- `-` bullets, one terse line each, for itemized changes:
  ```
  fix: optimize load times
  - parallel calls, no await
  - removed 500ms settle
  - connected shows earlier
  - new tests
  ```
- Plain context lines for rationale, numbers, or side notes:
  ```
  refactor: start: get WEBP to render on full dart instead of c++ lib
  1.1 - 1.6x slower but that's acceptable I think
  ```
  ```
  fix: added garbage collector for emotes
  >80 emotes = 1h ttl, <80 = 24h
  ```
- Multi-fix debugging commits may use numbered status lists:
  ```
  38c1140 4 attempted fixes, 3 successful
  1. system message not supposed to ping - fixed
  ...
  5. 7tv system messages not shown - ATTEMPTED, NOT fixed - will fix in future
  ```

If the why isn't guessable from the diff, put it in the body. Otherwise skip the body.

## Special cases

- Version bumps: subject is exactly `Version v0.X.Y`. Extra notes go in the body.
- Reverts: plain `git revert` output (`Revert "<original subject>"` + `This reverts commit <sha>.`). Don't hand-roll revert messages.
- Merges: default git format, optionally append a summary after the branch name:
  `Merge refactor/webp-emote-renderer: native webp renderer, disk-cache prioritizer, autocomplete stale-frame fix`
- try to stay under 50 characters on a subject, hard cap below 65 (see Subject line). Just put big stuff in the body, and use compacted language where possible (no rambling in commits!)

## Voice

Honest and human beats formal. Casual asides are fine (`sorry for the spam, this is for F-droid stuff`). WIP state should be declared, not hidden: `IN PROGRESS`, `INCOMPLETE`, `(untested)`, `BUGGY ASS COMMIT, DO NOT TOUCH`.

Write for someone skimming `git log`: intent first, mechanics second (or never). Play-by-play diffspeak ("changed X at line N of random_file") is noise; if the why needs a line number to explain, the commit is too big anyway.

Never: emoji, em-dashes, AI attribution footers, scopes, issue numbers.
