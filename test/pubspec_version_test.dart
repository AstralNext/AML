import 'dart:io';

import 'package:aml/src/app/pubspec_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses pubspec version without build', () {
    const yaml = 'name: aml\nversion: 1.0.0\n';
    final info = PubspecVersion.parseYaml(yaml);
    expect(info.version, '1.0.0');
    expect(info.buildNumber, isEmpty);
    expect(info.display, '1.0.0');
  });

  test('parses pubspec version with build and prerelease', () {
    const yaml = 'name: aml\nversion: 1.2.3-beta.1+42\n';
    final info = PubspecVersion.parseYaml(yaml);
    expect(info.version, '1.2.3-beta.1');
    expect(info.buildNumber, '42');
    expect(info.display, '1.2.3-beta.1 (42)');
  });

  test('baked constant matches repo pubspec.yaml', () {
    final yaml = File('pubspec.yaml').readAsStringSync();
    final fromFile = PubspecVersion.parseYaml(yaml);
    expect(
      kPubspecVersionRaw,
      fromFile.raw,
      reason: 'Update kPubspecVersionRaw in lib/src/app/pubspec_version.dart '
          'to match pubspec.yaml version:',
    );
  });
}
