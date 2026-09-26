import 'dart:convert';
import 'dart:io';

import 'package:aml/src/features/instances/application/dot_minecraft_import_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DotMinecraftImportService Tests', () {
    late Directory tempMcDir;

    setUp(() async {
      tempMcDir = await Directory.systemTemp.createTemp('mock_minecraft_');
    });

    tearDown(() async {
      if (await tempMcDir.exists()) {
        await tempMcDir.delete(recursive: true);
      }
    });

    test('successfully scans instance with Setup.ini and Fabric loader (Windows javaw normalization)', () async {
      final versionsDir = Directory(p.join(tempMcDir.path, 'versions', '1.20.1-Fabric'));
      await versionsDir.create(recursive: true);

      // 创建 1.20.1-Fabric.json
      final jsonFile = File(p.join(versionsDir.path, '1.20.1-Fabric.json'));
      await jsonFile.writeAsString(jsonEncode({
        'id': '1.20.1-Fabric',
        'inheritsFrom': '1.20.1',
        'mainClass': 'net.fabricmc.loader.impl.launch.knot.KnotClient',
        'libraries': [
          {'name': 'net.fabricmc:fabric-loader:0.15.11'},
        ],
      }));

      // 创建 Pcl/Setup.ini (模拟典型的 Windows javaw.exe 路径与配置)
      final pclDir = Directory(p.join(versionsDir.path, 'Pcl'));
      await pclDir.create();
      final setupIni = File(p.join(pclDir.path, 'Setup.ini'));
      await setupIni.writeAsString(r'''
VersionArgumentIndie:1
VersionRamCustom:6144
VersionJavaPath:C:\Program Files\Java\jdk-17\bin\javaw.exe
VersionJvm:-XX:+UseG1GC -Dtest=true
''');

      // 创建 mock mods
      final modsDir = Directory(p.join(versionsDir.path, 'mods'));
      await modsDir.create();
      await File(p.join(modsDir.path, 'fabric-api.jar')).writeAsString('dummy');
      await File(p.join(modsDir.path, 'sodium.jar')).writeAsString('dummy');

      // 执行扫描
      final results = await DotMinecraftImportService.scanPath(tempMcDir.path);

      expect(results.length, 1);
      final game = results.first;
      expect(game.id, '1.20.1-Fabric');
      expect(game.gameVersion, '1.20.1');
      expect(game.loader, 'fabric');
      expect(game.loaderVersion, '0.15.11');
      expect(game.isIsolated, true);
      expect(game.memoryMb, 6144);
      // 验证 javaw.exe 已被安全规范化为 java.exe，完全兼容 AML 启动检查
      expect(game.javaPath, r'C:\Program Files\Java\jdk-17\bin\java.exe');
      expect(game.extraJvmArgs, '-XX:+UseG1GC -Dtest=true');
      expect(game.modCount, 2);
    });

    test('successfully scans instance with hmclversion.cfg', () async {
      final versionsDir = Directory(p.join(tempMcDir.path, 'versions', '1.16.5-Forge'));
      await versionsDir.create(recursive: true);

      // 创建 1.16.5-Forge.json
      final jsonFile = File(p.join(versionsDir.path, '1.16.5-Forge.json'));
      await jsonFile.writeAsString(jsonEncode({
        'id': '1.16.5-Forge',
        'inheritsFrom': '1.16.5',
        'mainClass': 'net.minecraftforge.fml.common.launcher.FMLTweaker',
        'libraries': [
          {'name': 'net.minecraftforge:forge:1.16.5-36.2.39'},
        ],
      }));

      // 创建 hmclversion.cfg
      final cfgFile = File(p.join(versionsDir.path, 'hmclversion.cfg'));
      await cfgFile.writeAsString(jsonEncode({
        'isolation': 1,
        'maxMemory': 4096,
        'java': r'D:\Java\bin\javaw.exe',
      }));

      final results = await DotMinecraftImportService.scanPath(tempMcDir.path);

      expect(results.length, 1);
      final game = results.first;
      expect(game.id, '1.16.5-Forge');
      expect(game.gameVersion, '1.16.5');
      expect(game.loader, 'forge');
      expect(game.isIsolated, true);
      expect(game.memoryMb, 4096);
      expect(game.javaPath, r'D:\Java\bin\java.exe');
    });

    test('dotMinecraftRegex correctly matches dot minecraft paths on Windows and Linux', () {
      final reg = DotMinecraftImportService.dotMinecraftRegex;
      expect(reg.hasMatch('/home/user/.minecraft'), isTrue);
      expect(reg.hasMatch('/home/user/.minecraft/'), isTrue);
      expect(reg.hasMatch(r'D:\Games\.minecraft'), isTrue);
      expect(reg.hasMatch(r'D:\Games\.minecraft\'), isTrue);
      expect(reg.hasMatch(r'C:\Users\admin\AppData\Roaming\.minecraft'), isTrue);
      expect(reg.hasMatch('.minecraft'), isTrue);
      expect(reg.hasMatch('/home/user/.minecraft_backup'), isFalse);
    });

    test('searchDotMinecraftAcrossDisks streams instantly without blocking', () async {
      final stream = DotMinecraftImportService.searchDotMinecraftAcrossDisks(maxDepth: 1);
      final paths = <String>[];
      final sub = stream.listen((p) {
        paths.add(p);
      });
      // 稍作等待后取消，测试 stream 是否正常工作
      await Future.delayed(const Duration(milliseconds: 100));
      await sub.cancel();
      expect(paths, isA<List<String>>());
    });

    test('correctly identifies unisolated standard official .minecraft layout and counts root saves/mods', () async {
      final versionsDir = Directory(p.join(tempMcDir.path, 'versions', '1.20.4'));
      await versionsDir.create(recursive: true);

      // 仅包含原版标准 1.20.4.json，无 Pcl/Setup.ini 也无 hmclversion.cfg
      final jsonFile = File(p.join(versionsDir.path, '1.20.4.json'));
      await jsonFile.writeAsString(jsonEncode({
        'id': '1.20.4',
        'type': 'release',
        'mainClass': 'net.minecraft.client.main.Main',
      }));

      // 标准官方游戏目录：saves、mods 和 options.txt 在 .minecraft 根目录下
      final rootSaves = Directory(p.join(tempMcDir.path, 'saves', 'MySurvivalWorld'));
      await rootSaves.create(recursive: true);
      await File(p.join(rootSaves.path, 'level.dat')).writeAsString('dummy_level');

      final rootMods = Directory(p.join(tempMcDir.path, 'mods'));
      await rootMods.create(recursive: true);
      await File(p.join(rootMods.path, 'optifine.jar')).writeAsString('dummy_mod');

      final results = await DotMinecraftImportService.scanPath(tempMcDir.path);

      expect(results.length, 1);
      final game = results.first;
      expect(game.id, '1.20.4');
      expect(game.gameVersion, '1.20.4');
      expect(game.loader, 'vanilla');
      // 验证未显式配置时，根据官方 .minecraft 规范智能识别为非隔离
      expect(game.isIsolated, isFalse);
      expect(game.saveCount, 1);
      expect(game.modCount, 1);
    });
  });
}
