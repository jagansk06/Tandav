import 'tandav_platform_base.dart';

/// Fallback for a platform Tandav has no storage implementation for (neither
/// `dart:io` nor a browser). Present only so the conditional export in
/// `tandav_platform.dart` always resolves to something.
TandavPlatform createTandavPlatform() => throw UnsupportedError(
      'Tandav runs as the Android app or in a web browser.',
    );
