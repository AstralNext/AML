import 'package:aml/src/app/launch_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses instance-only launch link', () {
    final link = AmlLaunchLink.tryParse(
      'aml://launch/instance/local%3Aabc-123',
    );
    expect(link, isNotNull);
    expect(link!.instanceId, 'local:abc-123');
    expect(link.serverAddress, isNull);
    expect(link.worldFolder, isNull);
  });

  test('parses server launch link', () {
    final link = AmlLaunchLink.tryParse(
      'aml://launch/instance/local:abc?server=mc.example.com:25565',
    );
    expect(link!.instanceId, 'local:abc');
    expect(link.serverAddress, 'mc.example.com:25565');
    expect(link.worldFolder, isNull);
  });

  test('parses world launch link', () {
    final link = AmlLaunchLink.tryParse(
      'aml://launch/instance/local:abc?world=My%20World',
    );
    expect(link!.worldFolder, 'My World');
  });

  test('rejects server+world together', () {
    expect(
      AmlLaunchLink.tryParse(
        'aml://launch/instance/x?server=a&world=b',
      ),
      isNull,
    );
  });

  test('fromArgs picks first aml link', () {
    final link = AmlLaunchLink.fromArgs([
      '--something',
      'aml://launch/instance/id1?server=host:1',
      'aml://launch/instance/id2',
    ]);
    expect(link!.instanceId, 'id1');
    expect(link.serverAddress, 'host:1');
  });
}
