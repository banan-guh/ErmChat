#!/usr/bin/env bash
# Cuts a release: checks CHANGELOG.md, drafts the GitHub release notes for
# editing, bumps pubspec on develop, fast-forwards main to it, tags,
# publishes, closes the fixed-next issues and watches the store build.
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
# A big release is written by hand: its categories come as bare headings.
COMMITS="$(git rev-list --count --no-merges "$PREV..develop")"
category() {
  if ((COMMITS >= 20)); then printf '%s\n\n' "$1"; else section "$1" "$2"; fi
}
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
  ((COMMITS < 20)) || echo "// $COMMITS commits since $PREV: git log $PREV..develop"
  echo "$INTRO"
  echo
  echo "---"
  echo "### What Happened: ###"
  category "Architecture / Correctness Fixes" "$FIXES"
  category "New Features" "$FEATS"
  category "Also Fixed" "$ALSO"
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

# Main only fast-forwards to develop. Weblate's merges land on main, so
# develop takes them first, and the push refuses anything but a fast-forward.
git switch -q develop
git merge -q --ff-only origin/develop || die "develop has diverged from GitHub's"
if ! git merge -q --no-edit origin/main; then
  git merge --abort
  die "main does not merge cleanly into develop"
fi
sed -i -E "s/^version:.*/version: $VERSION+$((BUILD + 1))/" pubspec.yaml
git commit -q -am "Version $TAG beta" # REMOVE THIS when v1.0!! 
git tag "$TAG"
git push -q origin develop develop:main "$TAG"
git fetch -q . develop:main
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
