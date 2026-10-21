#!/usr/bin/env bash
# Cuts a release: checks CHANGELOG.md, drafts the GitHub release notes for
# editing, merges develop into main, bumps pubspec, tags, publishes, closes
# the fixed-next issues and watches the store build.
# Usage: tool/release.sh [x.y.z]   (default: the next patch)
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=banan-guh/ErmChat

die() { echo "release: $*" >&2; exit 1; }
ask() { read -r -p "$1 [y/N] " a; [[ $a == [yY]* ]]; }

[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
gh auth status > /dev/null 2>&1 || die "gh is not signed in"
git fetch -q origin

# Tags come from GitHub: local ones can be stale after a history rewrite.
remote_tags() {
  git ls-remote --tags --refs origin 'v*' | sed 's|.*refs/tags/||' | sort -V
}
PREV="$(remote_tags | tail -1)"
git fetch -q origin "refs/tags/$PREV:refs/tags/$PREV" ||
  die "local $PREV differs from GitHub's"
CUR="$(git show origin/main:pubspec.yaml | sed -nE 's/^version:[[:space:]]*//p' | head -1)"
NAME="${CUR%%+*}"
BUILD="${CUR##*+}"
IFS=. read -r MAJOR MINOR PATCH <<< "$NAME"
VERSION="${1:-$MAJOR.$MINOR.$((PATCH + 1))}"
TAG="v$VERSION"
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be x.y.z"
remote_tags | grep -qx "$TAG" && die "$TAG already exists"

# CHANGELOG.md is the Play and TestFlight notes. CI checks the same rules.
CHANGELOG="$(git show develop:CHANGELOG.md)"
[[ -n $CHANGELOG ]] || die "CHANGELOG.md is empty"
CHARS="$(git show develop:CHANGELOG.md | wc -m)"
((CHARS <= 500)) || die "CHANGELOG.md is $CHARS characters; Play allows 500"
git diff --quiet "$PREV" develop -- CHANGELOG.md &&
  die "CHANGELOG.md is unchanged since $PREV"
ITEMS="$(grep -c '^- ' <<< "$CHANGELOG" || true)"
if ((ITEMS < 3)); then
  ask "CHANGELOG.md lists $ITEMS changes, under the floor of 3. Release anyway?" ||
    exit 1
fi

echo "$PREV -> $TAG (build $((BUILD + 1)))"
echo
echo "$CHANGELOG"
echo

# The draft: commit titles since the last release, sorted into the usual
# sections, and the issues waiting on this release.
titles() {
  git log --no-merges --format=%s "$PREV..develop" |
    sed -nE "s/^($1): (.*)/- \2/p"
}
section() { [[ -z $2 ]] || printf '%s\n\n%s\n\n' "$1" "$2"; }
FIXES="$(titles fix)"
FEATS="$(titles feat)"
ALSO="$(titles 'perf|refactor|style')"
ISSUES="$(gh issue list -R "$REPO" --label fixed-next --state open \
  --json number,title -q '.[] | "\(.number)\t\(.title)"')"
ISSUE_LINES="$(cut -f1,2 --output-delimiter=', ' <<< "$ISSUES" |
  sed -E '/^$/d; s/^/- issue #/')"
[[ $VERSION == *.0 ]] && INTRO="feature drop." || INTRO="small patch:"

NOTES="$(git rev-parse --git-dir)/RELEASE_NOTES.md"
{
  echo "// Lines starting with // are dropped. Write the intro, trim the lists."
  echo "// CHANGELOG.md:"
  sed 's|^|//   |' <<< "$CHANGELOG"
  echo "$INTRO"
  echo
  echo "---"
  echo "### What Happened: ###"
  section "Architecture / Correctness Fixes" "$FIXES"
  section "New Features" "$FEATS"
  section "Also Fixed" "$ALSO"
  section "issues (fixed):" "$ISSUE_LINES"
  echo ")"
  echo
  echo "**Full Changelog**: https://github.com/$REPO/compare/$PREV...$TAG"
} > "$NOTES"
"${EDITOR:-nano}" "$NOTES"
sed -i '/^\/\//d' "$NOTES"
echo
cat "$NOTES"
echo
ask "Publish $TAG with these notes?" || die "stopped; nothing changed"

git switch -q main
git merge -q --ff-only origin/main
if ! git merge -q --no-edit develop; then
  git merge --abort
  git switch -q develop
  die "develop does not merge cleanly into main"
fi
sed -i -E "s/^version:.*/version: $VERSION+$((BUILD + 1))/" pubspec.yaml
git commit -q -am "Version $TAG"
git tag "$TAG"
git switch -q develop
git merge -q --ff-only main
git push -q origin main develop "$TAG"
gh release create "$TAG" -R "$REPO" --title "$TAG" --notes-file "$NOTES" \
  --verify-tag

while IFS=$'\t' read -r number _; do
  [[ -n $number ]] || continue
  gh issue close "$number" -R "$REPO" --comment "Out in $TAG."
  gh issue edit "$number" -R "$REPO" --remove-label fixed-next > /dev/null
done <<< "$ISSUES"

ask "Watch the store build?" || exit 0
sleep 10
RUN="$(gh run list -R "$REPO" -w main.yml --branch "$TAG" -L 1 \
  --json databaseId -q '.[0].databaseId')"
[[ -n $RUN ]] || die "no build found for $TAG"
until gh run watch "$RUN" -R "$REPO" --exit-status; do
  ask "The build failed. Rerun the failed jobs?" || exit 1
  gh run rerun "$RUN" -R "$REPO" --failed
  sleep 10
done
echo "$TAG is out."
