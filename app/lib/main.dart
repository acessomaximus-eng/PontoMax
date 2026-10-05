import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'src/config.dart';
import 'src/router.dart';
import 'src/services/offline_queue.dart';
import 'src/services/reminders.dart';
import 'src/state/session.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'pt_BR';
  await initializeDateFormatting('pt_BR');
  await AppConfig.load();
  unawaited(Reminders.init());
  runApp(const ProviderScope(child: PontoMaxApp()));
}

class PontoMaxApp extends ConsumerStatefulWidget {
  const PontoMaxApp({super.key});
  @override
  ConsumerState<PontoMaxApp> createState() => _PontoMaxAppState();
}

class _PontoMaxAppState extends ConsumerState<PontoMaxApp>
    with WidgetsBindingObserver {
  Timer? _sync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Sincroniza marcações off-line e o relógio periodicamente.
    _sync = Timer.periodic(const Duration(minutes: 1), (_) => _onResume());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sync?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResume();
  }

  void _onResume() {
    final session = ref.read(sessionProvider);
    if (session.status != SessionStatus.signedIn) return;
    ref.read(offlineQueueProvider.notifier).sync().catchError((_) => 0);
    ref.read(sessionProvider.notifier).refreshMe().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'PontoMax',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      routerConfig: router,
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
