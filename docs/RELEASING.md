# Releasing

## F-Droid changelogs

`fastlane/` exists for the F-Droid listing. Each release needs three changelog files in `fastlane/metadata/android/en-US/changelogs/`, one per split-ABI build:

- `10N.txt`
- `20N.txt`
- `40N.txt`

`N` is the `+N` build number in `pubspec.yaml` (for `0.5.8+14`, the files are `1014.txt`, `2014.txt`, `4014.txt`). Update them with every version bump. Old changelogs can be deleted.
