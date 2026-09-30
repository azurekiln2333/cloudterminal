import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/pair_screen.dart';
import 'state/app_store.dart';
import 'state/appearance.dart';
import 'state/remote_controller.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AppStore.open();
  runApp(CloudTerminalApp(
    store: store,
    controller: RemoteController(store: store),
  ));
}

class CloudTerminalApp extends StatefulWidget {
  const CloudTerminalApp({
    super.key,
    required this.store,
    required this.controller,
  });

  final AppStore store;
  final RemoteController controller;

  @override
  State<CloudTerminalApp> createState() => _CloudTerminalAppState();
}

class _CloudTerminalAppState extends State<CloudTerminalApp>
    with WidgetsBindingObserver {
  late final Appearance _appearance = Appearance(widget.store);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Phones kill sockets in the background; reconnect straight away
    // instead of waiting out the backoff when the user comes back.
    if (state == AppLifecycleState.resumed) widget.controller.reconnectNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _appearance,
      builder: (context, _) => MaterialApp(
        title: 'CloudTerminal',
        debugShowCheckedModeBanner: false,
        themeMode: _appearance.themeMode,
        theme: AppTheme.light(_appearance.seedColor),
        darkTheme: AppTheme.dark(_appearance.seedColor),
        home: _Root(
          controller: widget.controller,
          appearance: _appearance,
          store: widget.store,
        ),
      ),
    );
  }
}

/// Swaps between pairing and the main UI when the pairing changes.
class _Root extends StatelessWidget {
  const _Root({
    required this.controller,
    required this.appearance,
    required this.store,
  });

  final RemoteController controller;
  final Appearance appearance;
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: controller.pairing == null
            ? PairScreen(
                key: const ValueKey<String>('pair'),
                controller: controller,
                initialRelay: store.lastRelayUrl,
              )
            : HomeScreen(
                key: ValueKey<String>('home-${controller.pairing!.agentId}'),
                controller: controller,
                appearance: appearance,
              ),
      ),
    );
  }
}
