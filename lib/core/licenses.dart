import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Where the source code of the app is published.
const appSourceUrl = 'https://github.com/Gabirodz/learnmath';

/// Where someone who likes the app can support its author. A gift: nothing
/// in the app depends on it.
const appSupportUrl = 'https://buymeacoffee.com/gabirodz';

/// The copyright and licence line shown in Settings and on the licences page.
const appLegalese = 'Copyright © 2026 Axel Gabriel Rodriguez Zarate. '
    'Free software under the GNU General Public License, version 3 or '
    'later, with no warranty.';

var _registered = false;

/// Adds what Flutter cannot find by itself to the licences page (Settings,
/// About): the app's own licence, which is also that of eSpeak NG inside the
/// voice engine, and a word on what is downloaded at run time. The licences
/// of the Dart packages are collected by Flutter.
void registerAppLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['LearnMath', 'eSpeak NG (in the voice engine)'],
      await rootBundle.loadString('LICENSE'),
    );
    yield const LicenseEntryWithLineBreaks(
      ['Voices and other downloads'],
      'The voice models (Kokoro and others), kokoro-js, and Pyodide with '
      'SymPy are not part of the app: it downloads them when they are '
      'first used. Their licences, and the rest of the third-party '
      'software, are listed in THIRD_PARTY_NOTICES.md in the source code: '
      '$appSourceUrl',
    );
  });
}
