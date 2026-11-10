// v4.4.6: signature check — a build that is not signed with our
// key does not run. This stops someone who downloads the release
// APK, modifies it and re-signs it. It does NOT stop a rebuild from
// the public source (the check itself is in that source) — the
// license check (LicenseService) is the backstop for that: a build
// from cloned source has no app secret, so the license server
// refuses it.

import 'dart:io' show Platform;

import 'platform.dart';

class SecurityService {
  /// SHA-256 of the debug keystore certificate CI signs every
  /// release APK with (verified from the 4.4.5 APK with keytool).
  static const String expectedSignatureSha256 =
      '53756CDC4CF6C16F4E9D8A0ACEC29B0F08261FAB86AAC0D1151F5E9E464F8C35';

  /// True when this build is signed with our key (Android only).
  /// Fail-open on iOS / channel errors / unreadable signature: a
  /// broken check must never brick the genuine app.
  static Future<bool> isGenuineBuild() async {
    if (!Platform.isAndroid) return true;
    try {
      final sig = await NativePlatform.getSignatureSha256();
      if (sig.isEmpty) return true;
      return sig.toUpperCase() == expectedSignatureSha256;
    } catch (_) {
      return true;
    }
  }
}
