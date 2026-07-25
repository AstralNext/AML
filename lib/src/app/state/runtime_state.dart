import 'package:signals_flutter/signals_flutter.dart';

class RuntimeState {
  RuntimeState();

  final appDataDirectory = signal<String?>(null);
}
