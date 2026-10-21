/// iOS mention push goes through ermchat-notify (`notify/` in
/// ermchat-server): `POST <endpoint>/register` and `/unregister`. Empty
/// turns push off.
class PushConfig {
  static const String endpoint =
      'https://erm-machine-1.tail834800.ts.net/notify';
}
