import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/core/licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the licences page gets the GPL for the app and eSpeak NG, once',
      () async {
    registerAppLicenses();
    registerAppLicenses(); // a second call adds nothing
    final own = [
      await for (final e in LicenseRegistry.licenses)
        if (e.packages.contains('LearnMath')) e,
    ];
    expect(own, hasLength(1));
    expect(own.single.packages, contains('eSpeak NG (in the voice engine)'));
    final text = own.single.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(text, contains('Version 3, 29 June 2007'));

    final downloads = [
      await for (final e in LicenseRegistry.licenses)
        if (e.packages.contains('Voices and other downloads')) e,
    ];
    expect(downloads, hasLength(1));
    expect(downloads.single.paragraphs.first.text, contains(appSourceUrl));
  });

  test('the legal line names the licence', () {
    expect(appLegalese, contains('GNU General Public License, version 3'));
    expect(appLegalese, contains('no warranty'));
  });
}
