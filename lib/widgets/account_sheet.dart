import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../screens/login_screen.dart';

Future<void> showAccountSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: const Color(0xFF12151C),
    builder: (_) => const _AccountSheet(),
  );
}

class _AccountSheet extends StatefulWidget {
  const _AccountSheet();

  @override
  State<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<_AccountSheet> {
  final _auth = AuthService.instance;
  bool _busy = false;

  Future<void> _deleteAccount() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'Your account and synced data are deleted permanently. Photos on this phone are not affected.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      await _auth.deleteAccount();
      if (mounted) Navigator.pop(context);
    } on AuthFailure catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: ListenableBuilder(
          listenable: _auth,
          builder: (context, _) {
            if (!_auth.enabled) {
              return const ListTile(
                leading: Icon(Icons.cloud_off),
                title: Text('Accounts are off in this build'),
                subtitle: Text('Add Supabase settings to env.json to enable sign-in.'),
              );
            }
            if (!_auth.isSignedIn) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ListTile(
                    leading: Icon(Icons.person_outline),
                    title: Text('Not signed in'),
                    subtitle: Text('Sign in to sync your presets between devices.'),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        final nav = Navigator.of(context);
                        nav.pop();
                        nav.push(MaterialPageRoute<void>(
                          builder: (_) => const LoginScreen(canSkip: false),
                        ));
                      },
                      child: const Text('Sign in'),
                    ),
                  ),
                ],
              );
            }
            final avatar = _auth.avatarUrl;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: CircleAvatar(
                    backgroundImage: avatar != null ? NetworkImage(avatar) : null,
                    child: avatar == null ? const Icon(Icons.person) : null,
                  ),
                  title: Text(_auth.displayName),
                  subtitle: Text(_auth.user?.email ?? '', style: text.bodySmall),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            await _auth.signOut();
                            if (context.mounted) Navigator.pop(context);
                          },
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: _busy ? null : _deleteAccount,
                  style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                  child: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Delete account'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
