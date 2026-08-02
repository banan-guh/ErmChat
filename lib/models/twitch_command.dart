enum CommandPermission { everyone, mod, owner }

class TwitchCommand {
  final String name;
  final CommandPermission permission;
  const TwitchCommand({required this.name, required this.permission});
}
