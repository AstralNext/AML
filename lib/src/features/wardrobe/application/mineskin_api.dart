import 'dart:convert';
import 'dart:typed_data';

import 'package:aml/src/features/wardrobe/ui/public_skin_widgets.dart';
import 'package:http/http.dart' as http;

/// MineSkin 公开皮肤列表的一页结果。
class MineSkinPage {
  const MineSkinPage({required this.items, this.nextAfter});

  final List<MineSkinItem> items;

  /// 下一页游标；为 null 表示没有更多。
  final String? nextAfter;
}

/// MineSkin v2 API 客户端（皮肤库页面与皮肤编辑对话框共用）。
///
/// 详情与贴图按 key 全局缓存 Future：同一贴图在页面 / 对话框 / 多张卡片
/// 之间只请求一次；失败的结果也会被缓存（与原实现一致）。
class MineSkinApi {
  MineSkinApi._();

  static const _headers = {'User-Agent': 'AML/1.0'};
  static final _pngFutures = <String, Future<Uint8List?>>{};
  static final _detailFutures = <String, Future<MineSkinItem>>{};

  static Future<MineSkinPage> list({
    String? search,
    String? after,
    int size = 24,
  }) async {
    final query = <String, String>{'size': '$size'};
    final q = search?.trim();
    if (q != null && q.isNotEmpty) query['search'] = q;
    if (after != null && after.isNotEmpty) query['after'] = after;
    final uri = Uri.https('api.mineskin.org', '/v2/skins', query);
    final response = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('MineSkin 返回 HTTP ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final skins = (json['skins'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(MineSkinItem.fromJson)
        .toList();
    final pagination = json['pagination'] as Map<String, dynamic>?;
    final next = pagination?['next'] as Map<String, dynamic>?;
    return MineSkinPage(items: skins, nextAfter: next?['after'] as String?);
  }

  /// 贴图 PNG 字节（带缓存）；非 2xx / 超过 4MB / 网络失败返回 null。
  static Future<Uint8List?> pngFor(MineSkinItem item) {
    return _pngFutures.putIfAbsent(item.texture, () async {
      try {
        final response = await http
            .get(Uri.parse(item.textureUrl))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            response.bodyBytes.length > 4 * 1024 * 1024) {
          return null;
        }
        return response.bodyBytes;
      } catch (_) {
        return null;
      }
    });
  }

  /// 补全皮肤详情（variant 等，带缓存）；已有详情或请求失败时原样返回。
  static Future<MineSkinItem> detailsFor(MineSkinItem item) {
    if (item.hasDetails) return Future.value(item);
    return _detailFutures.putIfAbsent(item.uuid, () async {
      try {
        final response = await http
            .get(
              Uri.https('api.mineskin.org', '/v2/skins/${item.uuid}'),
              headers: _headers,
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return item;
        }
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final skin = json['skin'];
        if (skin is! Map<String, dynamic>) return item;
        return item.withDetails(skin);
      } catch (_) {
        return item;
      }
    });
  }
}
