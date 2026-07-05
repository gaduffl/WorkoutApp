import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/app_database.dart';
import 'data/repository.dart';
import 'state/app_controller.dart';
import 'ui/screens/home_screen.dart';

void main() {
  runApp(const MorningCoachApp());
}

class MorningCoachApp extends StatelessWidget {
  const MorningCoachApp({super.key});

  @override
  Widget build(BuildContext context) {
    final db = AppDatabase();
    final repo = Repository(db);
    final controller = AppController(repo)..init();

    return MultiProvider(
      providers: [
        Provider<Repository>.value(value: repo),
        ChangeNotifierProvider<AppController>.value(value: controller),
      ],
      child: MaterialApp(
        title: 'MorningCoach',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal), useMaterial3: true),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
