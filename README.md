# flutter_twitch_app

A Twitch chat viewer built with Flutter. It works, but it is a work in progress and still rough around the edges. Connect to channels, read chat, send messages, and browse reply threads.

## What it does

- Tabbed multi-channel chat with swipeable views
- Live messages via Twitch EventSub WebSocket
- Send messages through the Helix API
- Reply threads with inline view
- Mentions and whispers panel
- Emotes across Twitch, BTTV, FFZ, and 7TV
- Badges for mods, VIPs, subscribers, etc.
- Emote and username autocomplete
- Slash commands (`/ban`, `/timeout`, `/clear`, `/me`, etc.)
- System messages for subs, cheers, raids, bans
- Dark mode toggle

## Commands

```
flutter run        # launch on connected device or emulator
flutter test       # run all tests
flutter analyze    # static analysis
dart format .      # format all files
```

## License

MIT
