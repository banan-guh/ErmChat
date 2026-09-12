import 'connection.dart';
import 'events.dart';

/// Read-only IRC socket: joins channels and emits raw frames. Only this
/// socket JOINs channels; the write socket ([IrcService]) stays join-free so
/// Twitch counts one JOIN per channel against the rate limit.
class IrcReadService extends IrcConnection {
  IrcReadService({super.connectivityService, super.joinBudget})
    : super(role: IrcSocketRole.read);

  @override
  String get debugPrefix => 'IRC read';
}
