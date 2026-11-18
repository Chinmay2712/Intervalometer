import 'dart:io';

import 'package:flutter/material.dart';

import '../auth/auth_service.dart';

/// "Continue with Google / Apple" or skip. Pops itself after success when it
/// was pushed from the account sheet.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.canSkip = true});
  final bool canSkip;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _auth = AuthService.instance;
  String? _busy; // which provider is running
  String? _error;

  Future<void> _run(String provider, Future<bool> Function() signIn) async {
    setState(() {
      _busy = provider;
      _error = null;
    });
    try {
      final ok = await signIn();
      if (ok && mounted && Navigator.of(context).canPop() && _auth.isSignedIn) {
        Navigator.of(context).pop();
      }
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Apple requires the Apple button whenever Google is offered on iOS.
    final appleFirst = Platform.isIOS;

    final google = _ProviderButton(
      label: 'Continue with Google',
      icon: const Text('G', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
      busy: _busy == 'google',
      onPressed: _busy == null ? () => _run('google', _auth.signInWithGoogle) : null,
    );
    final apple = _ProviderButton(
      label: 'Continue with Apple',
      icon: const Icon(Icons.apple, size: 22),
      busy: _busy == 'apple',
      filled: true,
      onPressed: _busy == null ? () => _run('apple', _auth.signInWithApple) : null,
    );

    return Scaffold(
      appBar: Navigator.of(context).canPop() ? AppBar(backgroundColor: Colors.transparent) : null,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),
              const Icon(Icons.auto_awesome, size: 56, color: Color(0xFF7FB2FF)),
              const SizedBox(height: 16),
              Text('VALOMETER',
                  textAlign: TextAlign.center,
                  style: text.headlineMedium?.copyWith(letterSpacing: 6, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'Manual camera and intervalometer for the night sky',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: Colors.white60),
              ),
              const Spacer(flex: 3),
              if (appleFirst) ...[apple, const SizedBox(height: 12), google]
              else ...[google, const SizedBox(height: 12), apple],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 12),
              if (widget.canSkip)
                TextButton(
                  onPressed: _busy == null ? _auth.continueAsGuest : null,
                  child: const Text('Continue without an account'),
                ),
              const SizedBox(height: 8),
              Text(
                'An account only syncs your presets. Shooting works offline without one.',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: Colors.white38),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    required this.label,
    required this.icon,
    required this.busy,
    required this.onPressed,
    this.filled = false,
  });

  final String label;
  final Widget icon;
  final bool busy;
  final bool filled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        busy
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : icon,
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ],
    );
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(52)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    );
    return filled
        ? FilledButton(
            onPressed: onPressed,
            style: style.copyWith(
              backgroundColor: const WidgetStatePropertyAll(Colors.white),
              foregroundColor: const WidgetStatePropertyAll(Colors.black),
            ),
            child: child,
          )
        : OutlinedButton(onPressed: onPressed, style: style, child: child);
  }
}
