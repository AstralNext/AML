import 'package:signals_flutter/signals_flutter.dart';

class MinecraftState {
  MinecraftState();

  final modrinthUrl = signal<String>("https://modrinth.com/");
  final modrinthApiUrl = signal<String>("https://api.modrinth.com/v2/");
  final modrinthApiUrlV3 = signal<String>("https://api.modrinth.com/v3/");
  final modrinthSocketUrl = signal<String>("wss://api.modrinth.com/");
  final metaUrl = signal<String>("https://launcher-meta.modrinth.com/");

  final currentFabricFormatVersion = signal<int>(0);
  final currentForgeFormatVersion = signal<int>(0);
  final currentQuiltFormatVersion = signal<int>(0);
  final currentNeoForgeFormatVersion = signal<int>(0);
  final currentFormatVersion = signal<int>(0);
}
