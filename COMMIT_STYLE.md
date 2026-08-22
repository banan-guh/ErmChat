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

## Parenthetical asides

Append `(context)` to the subject for caveats, scope limits, or pointers:

- `fix (attempt): oauth smooth out`
- `feat: added twitch overlay (ONLY for self) - twitch limitation, ToS`
- `c8e1923 full audit / correctness / bugs rewrite (look at PLAN.md)`
- `a64844c refactor: merge tests into less files (tired of file change bloat)`

Pointers to docs are fair game: `(look at PLAN.md)`, `check PLAN.md`.

## Body (optional, use for anything non-obvious)

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
- try to not exceed 50-60 characters on commit, HARD limit is 100 but do not unless absolutely necessary. just put big stuff in the body, and use compacted language where possible (no rambling in commits!)

## Voice

Honest and human beats formal. Casual asides are fine (`sorry for the spam, this is for F-droid stuff`). WIP state should be declared, not hidden: `IN PROGRESS`, `INCOMPLETE`, `(untested)`, `BUGGY ASS COMMIT, DO NOT TOUCH`.

Never: emoji, em-dashes, AI attribution footers, scopes, issue numbers.
