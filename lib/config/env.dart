/// Build-time configuration, passed with
/// `flutter run --dart-define-from-file=env.json` (see env.example.json).
///
/// Nothing secret lives here: the Supabase publishable key (sb_publishable_...) and OAuth
/// client IDs are meant to ship inside the app. Row Level Security on the
/// database is what protects user data.
class Env {
  const Env._();

  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  /// "Web application" OAuth client ID from Google Cloud. Supabase verifies
  /// Google ID tokens against this, on both Android and iOS.
  static const googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  /// "iOS" OAuth client ID from Google Cloud (iOS builds only).
  static const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  /// Deep link Supabase returns to after browser-based sign-in (Apple on Android).
  static const authRedirect = 'com.valometer.valometer://login-callback';

  /// ON HOLD (Nov 2026): login and accounts are hidden from the app. All the
  /// sign-in code and the Supabase project stay in place. Set this to true
  /// to bring back the login screen and the account button.
  static const accountsEnabled = false;

  static bool get hasSupabase => supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;
  static bool get hasGoogle => googleWebClientId.isNotEmpty;
}
