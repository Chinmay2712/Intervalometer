import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth/auth_gate.dart';
import 'auth/auth_service.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await AuthService.instance.init();
  runApp(const ValometerApp());
}

class ValometerApp extends StatelessWidget {
  const ValometerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Valometer',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      builder: (context, child) => NightVisionFilter(child: child!),
      home: const AuthGate(),
    );
  }
}
