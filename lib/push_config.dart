/// iOS mention push goes through ermchat-notify (`notify/` in
/// ermchat-server): `POST <endpoint>/register` and `/unregister`. Empty
/// turns push off.
class PushConfig {
  // Off until the server has its APNs key.
  static const String endpoint = '';
  // static const String endpoint =
  //     'https://erm-machine-1.tail834800.ts.net/notify';
}
