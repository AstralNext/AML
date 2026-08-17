/// Map Rust/installer English progress strings to short Chinese copy.
String humanizeProgressMessage(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '准备中…';

  final lower = text.toLowerCase();

  // Internal progress markers — keep invisible to users.
  if (text.startsWith('__INSTANCE_CREATED__:')) return '正在创建实例…';

  if (lower.contains('install complete') ||
      lower.contains('download complete') ||
      lower.contains('modpack installed') ||
      lower.startsWith('installed ') ||
      lower == 'done' ||
      lower.contains('安装成功') ||
      lower.contains('复制完成') ||
      lower.contains('重装完成')) {
    return text.contains('成功') || text.contains('完成') || text.contains('已')
        ? text
        : '安装完成';
  }

  if (lower.contains('download stalled') ||
      lower.contains('下载停滞') ||
      lower.contains('连接超时') ||
      lower.contains('timed out') ||
      (lower.contains('timeout') && lower.contains('download'))) {
    return '下载超时或网络中断，请稍后重试（将自动尝试镜像回退）';
  }

  if (lower.contains('pack files') || lower.contains('modpack files')) {
    return '正在下载模组文件…';
  }
  if (lower.contains('downloading pack') || lower.contains('downloading java')) {
    if (lower.contains('java')) return '正在下载 Java…';
    return '正在下载整合包…';
  }
  if (lower.contains('installing modpack')) {
    return '正在安装整合包…';
  }
  if (lower.contains('downloading client')) {
    return '正在下载客户端…';
  }
  if (lower.contains('downloading libraries')) {
    return '正在下载依赖库…';
  }
  if (lower.contains('downloading assets')) {
    return '正在下载游戏资源…';
  }
  if (lower.contains('downloading log config')) {
    return '正在下载日志配置…';
  }
  if (lower.contains('downloading minecraft files')) {
    return '正在下载 Minecraft 文件…';
  }

  final fetchingModrinth = RegExp(
    r'Fetching Modrinth version\s+(.+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (fetchingModrinth != null) {
    return '正在获取 Modrinth 版本信息…';
  }

  final fetchingPack = RegExp(
    r'Fetching modpack version\s+(.+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (fetchingPack != null) {
    return '正在获取整合包版本信息…';
  }

  final retrying = RegExp(
    r'Retrying download \(attempt\s+(\d+)/(\d+),\s*mirror\s+(\d+)/(\d+)\)',
    caseSensitive: false,
  ).firstMatch(text);
  if (retrying != null) {
    return '下载失败，正在重试 '
        '(${retrying.group(1)}/${retrying.group(2)}，'
        '镜像 ${retrying.group(3)}/${retrying.group(4)})…';
  }

  final retrySimple = RegExp(
    r'Retrying download \((\d+)/(\d+)\)',
    caseSensitive: false,
  ).firstMatch(text);
  if (retrySimple != null) {
    return '下载失败，正在重试 '
        '(${retrySimple.group(1)}/${retrySimple.group(2)})…';
  }

  final creatingInstance = RegExp(
    r'Creating instance\s+(.+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (creatingInstance != null) {
    return '正在创建实例 ${creatingInstance.group(1)!.trim()}…';
  }

  final downloadingPack = RegExp(
    r'Downloading pack file\s+(.+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (downloadingPack != null) {
    return '正在下载整合包文件 ${downloadingPack.group(1)!.trim()}…';
  }

  final downloadingDep = RegExp(
    r'Installing dependency\s+(.+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (downloadingDep != null) {
    return '正在安装依赖 ${downloadingDep.group(1)!.trim()}…';
  }

  final downloadingNamed = RegExp(
    r'Downloading\s+(.+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (downloadingNamed != null) {
    final name =
        downloadingNamed.group(1)!.trim().replaceAll(RegExp(r'[.…]+$'), '');
    final nameLower = name.toLowerCase();
    if (nameLower.contains('minecraft files')) {
      return '正在下载 Minecraft 文件…';
    }
    if (nameLower == 'client') return '正在下载客户端…';
    if (nameLower == 'libraries') return '正在下载依赖库…';
    if (nameLower == 'assets') return '正在下载游戏资源…';
    if (nameLower == 'log config') return '正在下载日志配置…';
    if (nameLower.contains('minecraft')) {
      return '正在下载 Minecraft…';
    }
    return '正在下载 $name…';
  }

  if (lower.contains('resolving version metadata')) {
    return '正在解析版本元数据…';
  }
  if (lower.contains('resolving required dependencies') ||
      lower.contains('resolving dependencies')) {
    return '正在解析依赖…';
  }
  if (lower.contains('extracting overrides')) {
    return '正在解压覆盖文件…';
  }
  if (lower.contains('extracting natives')) {
    return '正在解压原生库…';
  }
  if (lower.contains('indexing installed content') ||
      lower.contains('indexing')) {
    return '正在索引已安装内容…';
  }
  if (lower.contains('reading mrpack')) {
    return '正在读取整合包…';
  }
  if (lower.contains('skipped dependency')) {
    return '已跳过依赖安装…';
  }
  if (lower.contains('running loader processors') ||
      lower.contains('running processors')) {
    return '正在运行加载器处理器…';
  }
  if (lower.contains('installing minecraft') ||
      lower.contains('minecraft + loader')) {
    return '正在安装 Minecraft 与加载器…';
  }
  if (lower.contains('extracting')) return '正在解压…';
  if (lower.contains('validating') || lower.contains('verifying')) {
    return '正在校验文件…';
  }
  if (lower.contains('fetching')) return '正在获取信息…';
  if (lower.contains('resolving')) return '正在解析…';
  if (lower.contains('preparing') || lower.contains('准备中')) {
    return '准备中…';
  }
  if (lower.startsWith('安装失败') ||
      lower.startsWith('复制失败') ||
      lower.startsWith('重装失败')) {
    return text;
  }

  // Already Chinese or unknown — keep as-is.
  return text;
}
