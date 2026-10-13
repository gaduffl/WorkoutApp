import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/updates/app_version.dart';

void main() {
  test('a tag, a pubspec version and an asset spelling parse alike', () {
    for (final raw in ['v0.42.0+71', '0.42.0+71', ' v0.42.0-71 ']) {
      expect(
        AppVersion.tryParse(raw),
        const AppVersion(name: '0.42.0', build: 71),
      );
    }
    expect(AppVersion.tryParse('1.2.3'), const AppVersion(name: '1.2.3'));
  });

  test('anything that is not a release version is rejected, not guessed', () {
    for (final raw in [
      '',
      'latest',
      'v1.2',
      '1.2.3.4',
      '1.2.3+x',
      'v1.2.3-beta',
    ]) {
      expect(AppVersion.tryParse(raw), isNull, reason: raw);
    }
  });

  test('the build number decides, because Android enforces only that', () {
    final installed = AppVersion.tryParse('0.42.0+71')!;
    expect(AppVersion.tryParse('0.43.0+72')!.isNewerThan(installed), isTrue);
    expect(AppVersion.tryParse('0.42.0+72')!.isNewerThan(installed), isTrue);
    expect(AppVersion.tryParse('0.42.0+71')!.isNewerThan(installed), isFalse);
    // A higher name with a lower build cannot be installed over this one.
    expect(AppVersion.tryParse('0.50.0+70')!.isNewerThan(installed), isFalse);
  });

  test('names compare numerically when a source omits the build number', () {
    final installed = AppVersion.tryParse('0.9.0+10')!;
    expect(AppVersion.tryParse('0.10.0')!.isNewerThan(installed), isTrue);
    expect(AppVersion.tryParse('0.9.0')!.isNewerThan(installed), isFalse);
  });
}

