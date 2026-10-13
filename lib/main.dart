import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'data/app_database.dart';
import 'data/repository.dart';
import 'models/user_settings.dart';
import 'state/app_controller.dart';
import 'ui/screens/home_screen.dart';
import 'ui/update_section.dart';
import 'updates/apk_installer.dart';
import 'updates/update_controller.dart';
import 'updates/update_downloader.dart';
import 'updates/update_settings.dart';
import 'updates/update_work_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MorningCoachApp());
}

class MorningCoachApp extends StatefulWidget {
  const MorningCoachApp({super.key});

  @override
  State<MorningCoachApp> createState() => _MorningCoachAppState();
}

class _MorningCoachAppState extends State<MorningCoachApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _routes = UpdateRouteChanges();
  late final Repository _repo;
  late final AppController _controller;
  late final Dio _updateDio;
  late final UpdateController _updates;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _repo = Repository(AppDatabase());
    _controller = AppController(_repo, workoutDraftPersistenceEnabled: true);
    _updateDio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    _updates = UpdateController(
      installer: MethodChannelApkInstaller(),
      settingsStore: UpdateSettingsStore(),
      tokenStore: UpdateTokenStore(),
      downloader: UpdateDownloader(
        dio: _updateDio,
        directory: () async =>
            Directory('${(await getTemporaryDirectory()).path}/updates'),
      ),
      sourceFactory: updateSourceFactoryFor(_updateDio),
      workInFlight: () =>
          appHasUpdateWorkInProgress(_controller, _navigatorKey.currentState),
      workChanges: Listenable.merge([_controller, _routes]),
      noticeFor: (version) => updateNoticeFor(
        _controller.settings.language == AppLanguage.de
            ? UpdateStrings.german
            : UpdateStrings.english,
        version,
      ),
    );
    _lifecycle = AppLifecycleListener(onStateChange: _updates.lifecycleChanged);
    unawaited(_controller.init());
    unawaited(_updates.checkInBackground());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _updates.dispose();
    _updateDio.close();
    _controller.dispose();
    _routes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      Provider<Repository>.value(value: _repo),
      ChangeNotifierProvider<AppController>.value(value: _controller),
      ChangeNotifierProvider<UpdateController>.value(value: _updates),
    ],
    child: Consumer<AppController>(
      builder: (context, controller, _) => MaterialApp(
        navigatorKey: _navigatorKey,
        navigatorObservers: [_routes],
        title: 'MorningCoach',
        locale: Locale(
          controller.settings.language == AppLanguage.de ? 'de' : 'en',
        ),
        supportedLocales: const [Locale('en'), Locale('de')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        builder: (context, child) => Column(
          children: [
            const SafeArea(bottom: false, child: UpdateCountdownBanner()),
            Expanded(child: child!),
          ],
        ),
        home: const HomeScreen(),
      ),
    ),
  );
}

