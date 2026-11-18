import 'package:flutter/material.dart';

import '../screens/camera_screen.dart';
import '../screens/login_screen.dart';
import 'auth_service.dart';

/// Shows the login screen until the user signs in or chooses guest mode.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) => auth.needsLogin ? const LoginScreen() : const CameraScreen(),
    );
  }
}
