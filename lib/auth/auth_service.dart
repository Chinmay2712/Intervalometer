import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

/// Thrown for problems worth showing to the user. Cancelling a sign-in is
/// not an error and never throws.
class AuthFailure implements Exception {
  AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sign-in with Google / Apple through Supabase, plus "continue as guest".
///
/// The camera works fully offline without an account; signing in is only
/// needed for features that sync (presets, later).
class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _guestKey = 'auth.guest';

  bool _guest = false;
  bool _googleReady = false;

  /// False when accounts are switched off ([Env.accountsEnabled]) or the app
  /// was built without Supabase settings. When false, Supabase is never
  /// initialised and the app starts straight on the camera.
  bool get enabled => Env.accountsEnabled && Env.hasSupabase;

  SupabaseClient get _client => Supabase.instance.client;

  User? get user => enabled ? _client.auth.currentUser : null;
  bool get isSignedIn => user != null;

  /// The user chose "Continue without account" (or Supabase isn't configured).
  bool get isGuest => !enabled || _guest;

  /// Whether to show the login screen at start-up.
  bool get needsLogin => enabled && !isSignedIn && !_guest;

  Future<void> init() async {
    if (enabled) {
      await Supabase.initialize(url: Env.supabaseUrl, publishableKey: Env.supabasePublishableKey);
      _client.auth.onAuthStateChange.listen((_) => notifyListeners());
    }
    final prefs = await SharedPreferences.getInstance();
    _guest = prefs.getBool(_guestKey) ?? false;
  }

  Future<void> continueAsGuest() async {
    _guest = true;
    (await SharedPreferences.getInstance()).setBool(_guestKey, true);
    notifyListeners();
  }

  Future<void> _clearGuest() async {
    _guest = false;
    (await SharedPreferences.getInstance()).remove(_guestKey);
  }

  // ------------------------------------------------------------- Google

  /// Native Google account picker, then exchanges the ID token with Supabase.
  /// Returns false if the user cancelled.
  Future<bool> signInWithGoogle() async {
    if (!Env.hasGoogle) {
      throw AuthFailure('Google sign-in is not configured (GOOGLE_WEB_CLIENT_ID missing).');
    }
    final google = GoogleSignIn.instance;
    if (!_googleReady) {
      await google.initialize(
        clientId: Platform.isIOS && Env.googleIosClientId.isNotEmpty ? Env.googleIosClientId : null,
        serverClientId: Env.googleWebClientId,
      );
      _googleReady = true;
    }

    try {
      final account = await google.authenticate(scopeHint: const ['email', 'profile']);
      final idToken = account.authentication.idToken;
      if (idToken == null) throw AuthFailure('Google did not return an ID token.');

      const scopes = ['email', 'profile'];
      final authorization = await account.authorizationClient.authorizationForScopes(scopes) ??
          await account.authorizationClient.authorizeScopes(scopes);

      await _client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: authorization.accessToken,
      );
      await _clearGuest();
      return true;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      throw AuthFailure('Google sign-in failed: ${e.description ?? e.code.name}');
    } on AuthException catch (e) {
      throw AuthFailure(e.message);
    }
  }

  // -------------------------------------------------------------- Apple

  /// iOS: native Apple sheet. Android: Apple's web page in the browser,
  /// which returns to the app through [Env.authRedirect].
  /// Returns false if the user cancelled.
  Future<bool> signInWithApple() async {
    try {
      if (Platform.isIOS) {
        final rawNonce = _client.auth.generateRawNonce();
        final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
        final credential = await SignInWithApple.getAppleIDCredential(
          scopes: const [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
          nonce: hashedNonce,
        );
        final idToken = credential.identityToken;
        if (idToken == null) throw AuthFailure('Apple did not return an identity token.');
        await _client.auth.signInWithIdToken(
          provider: OAuthProvider.apple,
          idToken: idToken,
          nonce: rawNonce,
        );
        // Apple only sends the name on the very first sign-in: keep it.
        final name = [credential.givenName, credential.familyName].whereType<String>().join(' ');
        if (name.isNotEmpty) {
          await _client.auth.updateUser(UserAttributes(data: {'full_name': name}));
        }
      } else {
        // Session arrives later through the deep link; onAuthStateChange
        // notifies listeners when it does.
        final launched = await _client.auth.signInWithOAuth(
          OAuthProvider.apple,
          redirectTo: Env.authRedirect,
          authScreenLaunchMode: LaunchMode.externalApplication,
        );
        if (!launched) return false;
      }
      await _clearGuest();
      return true;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return false;
      throw AuthFailure('Apple sign-in failed: ${e.message}');
    } on AuthException catch (e) {
      throw AuthFailure(e.message);
    }
  }

  // ------------------------------------------------------------ Account

  Future<void> signOut() async {
    if (!enabled) return;
    if (_googleReady) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
    await _client.auth.signOut();
    notifyListeners();
  }

  /// Permanently deletes the account and its data (required by the App Store
  /// for apps that let users create accounts). Runs the `delete-account`
  /// Edge Function, which holds the admin key server-side.
  Future<void> deleteAccount() async {
    if (!isSignedIn) return;
    try {
      await _client.functions.invoke('delete-account', method: HttpMethod.post);
    } on FunctionException catch (e) {
      throw AuthFailure('Could not delete the account (${e.status}). Try again later.');
    }
    await signOut();
  }

  String get displayName {
    final meta = user?.userMetadata ?? const {};
    return (meta['full_name'] ?? meta['name'] ?? user?.email ?? 'Signed in') as String;
  }

  String? get avatarUrl => (user?.userMetadata?['avatar_url'] ?? user?.userMetadata?['picture']) as String?;
}
