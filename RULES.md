# Rules

Behavioral rules for anyone working on ermchat, human or agent. AGENTS.md covers what to know before editing; this file covers how to behave. Read it before committing or delegating work.

## Commits

Read this section before EVERY commit. Follow it exactly.

Format: `<type>: <summary>`

- Types: fix, refactor, feat, chore, style, perf, ci.
- The summary is a short jab saying WHAT changed. Not the goal, not the why.
- Target 4 words. HARD MAX 8. <- for humans only: just do whatever fits, <50 chars is a good baseline
- Lowercase, imperative, no trailing period.
- Two related changes can comma-separate inside the cap, otherwise split commits (don't have to if it's too hard, just ship as one). <- humans: do whatever
- Body: default NONE. Only if the subject cannot fit without rewording, a few plain words. No bullets, no essays, no play-by-play narration.
- Specials: version bumps are exactly `Version v0.X.Y`; reverts are plain `git revert` output; merges stay git-default.
- Never: emoji, em-dashes, scopes, ticket refs.

Good: `fix: recents filled bad aliases`, `feat: add r8 minify`
Bad: `feat: add media upload with EXIF stripping so users can share screenshots safely`

## Code consistency

- Use `InkWell` (not `GestureDetector`) for `onLongPress` in scrollable contexts.
- Apply message features to both the main chat and the thread panel.
- Emote providers: static `fetchGlobal()`/`fetchChannel(channelId)` (7TV exposes `fetchChannelResponse`); dedup priority 7TV > BTTV > FFZ > Twitch.
- NO em-dashes in new code; avoid non-ASCII unless necessary.

## Subagents

When delegating to subagents (Task/explore agents):

Spawn one when:
- The search is open-ended and multi-round (where is X handled across many files).
- You need a broad question answered ("how does Y flow end to end") and only the answer matters.
- Several independent lookups can run at the same time.

Search directly instead when:
- You already know the file path or symbol.
- It is a single grep or read away.

When spawning:
- Write a detailed self-contained prompt: repo context, exact task, what to return.
- State explicitly whether the task is research-only or writes code.
- Batch independent spawns in one go; never duplicate delegated work yourself.
- Spot-check findings against real files before acting on them; agents can be wrong.
- Subagents never commit and never run destructive commands. They report back, you act.

## Good practice

- Before claiming done: `dart format .`, `flutter analyze`, and run the tests that cover the change (`flutter test` when unsure).
- Never commit unless explicitly asked.
- Minimal diffs. Match surrounding style. No drive-by refactors.
- Keep TODO.md markers current as work lands or gets skipped (`x` finished, `+` finished untested, `-` skip, `*` pay attention).
- If you can't figure something out: SEARCH THE WEB!!! if you have a tool to do that (e.g. exa web search), use that.