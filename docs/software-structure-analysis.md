# AML Software Structure Analysis

## 1. Scope

本文仅分析当前有效代码路径 `lib/src`，并以最新重构后的架构为准。

## 2. 当前结论

AML 已完成“GetIt + signals_flutter”主线收敛，形成统一依赖入口与状态边界：

- `get_it`：负责依赖生命周期与装配顺序
- `signals_flutter`：负责应用状态与 UI 响应
- `AppStore`：薄 facade，仅用于聚合已注入 state store
- 主题体系：统一走 `AppThemeTokens` 语义色值

## 3. 启动与装配链路

启动顺序：

1. `lib/main.dart`
2. `lib/src/app/bootstrap.dart`
3. `lib/src/app/di/service_locator.dart`
4. `lib/src/app/aml_app.dart`
5. `lib/src/features/shell/ui/main_screen.dart`

`bootstrap()` 负责：

- 初始化 Flutter binding
- 获取 app support 目录并写入 runtime state
- 初始化 DI 容器（repositories -> services -> stores -> app facade）
- 初始化 Rust runtime
- 初始化窗口
- 注册调试命令

## 4. 目录结构（定稿）

```text
lib/src/
  app/
    aml_app.dart
    app_store.dart
    bootstrap.dart
    di/
      service_locator.dart
    state/
  features/
    debug/
    discover/
    home/
    instances/
    java/
    resource/
    settings/
    shell/
    wardrobe/
  shared/
    theme/
    widgets/
  rust/
```

## 5. 分层职责

### 5.1 app

- `di/service_locator.dart`：唯一注册入口与生命周期管理
- `state/*`：全局 store（navigation/runtime/progress/minecraft）
- `app_store.dart`：聚合 facade，不再自行构造依赖

### 5.2 features

- `application`：store/service 编排与业务流程
- `data`：repository / datasource
- `domain`：模型与约束
- `ui`：页面与组件编排（通过 DI + Watch 消费状态）

### 5.3 shared

- `theme`：preset + token + 访问扩展
- `widgets`：复用组件（不承担业务依赖装配）

## 6. 核心依赖方向

统一依赖方向如下：

```text
ui -> store -> service/repository
```

约束：

- UI 不直接 new service/repository
- service 不直接读取全局静态对象
- state 不自行 new repository，统一构造注入

## 7. 关键业务流

### 7.1 设置持久化

1. `SettingsRegistry.initialize()`
2. 各 settings store 从 repository hydrate
3. signal 变化触发防抖持久化（300ms）
4. 写入 app support 目录下 JSON

### 7.2 Java 安装/检测

1. `JavaSettingsPage` 调用 `JavaDownloadService`
2. service 更新 `ProgressStore`
3. `RustJavaDownloadDataSource` 调用 FRB
4. Rust 侧执行下载/校验/提取

### 7.3 主题切换

1. UI 修改 `UiSettingsState.themePresetId`
2. `AmlApp` 通过 `Watch` 重建主题
3. 组件通过 `context.tokens` 读取语义颜色

## 8. 已完成的重构点

- 统一 DI 基座与注册顺序
- settings/java/resource/ui store 改为构造注入
- Java 服务去除 `AppStore()` 直连依赖
- 主要 UI 调用切到 `getIt<Store>() + Watch`
- token 旧命名收敛到 `color*` 语义命名
- 文档与结构说明同步到当前实现

## 9. 后续建议

- 增加 settings/repository 与 java service 的单元测试
- 为关键链路补充最小集成回归（主题切换、Java 安装、discover 渲染）
- 持续保持“新增功能必须通过 DI 注入”的代码评审规则
# AML Software Structure Analysis

## 1. Scope

本文仅分析当前有效代码路径 `lib/src`，并以最新重构后的架构为准。

## 2. 当前结论

AML 已完成“GetIt + signals_flutter”主线收敛，形成统一依赖入口与状态边界：

- `get_it`：负责依赖生命周期与装配顺序
- `signals_flutter`：负责应用状态与 UI 响应
- `AppStore`：薄 facade，仅用于聚合已注入 state store
- 主题体系：统一走 `AppThemeTokens` 语义色值

## 3. 启动与装配链路

启动顺序：

1. `lib/main.dart`
2. `lib/src/app/bootstrap.dart`
3. `lib/src/app/di/service_locator.dart`
4. `lib/src/app/aml_app.dart`
5. `lib/src/features/shell/ui/main_screen.dart`

`bootstrap()` 负责：

- 初始化 Flutter binding
- 获取 app support 目录并写入 runtime state
- 初始化 DI 容器（repositories -> services -> stores -> app facade）
- 初始化 Rust runtime
- 初始化窗口
- 注册调试命令

## 4. 目录结构（定稿）

```text
lib/src/
  app/
    aml_app.dart
    app_store.dart
    bootstrap.dart
    di/
      service_locator.dart
    state/
  features/
    debug/
    discover/
    home/
    instances/
    java/
    resource/
    settings/
    shell/
    wardrobe/
  shared/
    theme/
    widgets/
  rust/
```

## 5. 分层职责

### 5.1 app

- `di/service_locator.dart`：唯一注册入口与生命周期管理
- `state/*`：全局 store（navigation/runtime/progress/minecraft）
- `app_store.dart`：聚合 facade，不再自行构造依赖

### 5.2 features

- `application`：store/service 编排与业务流程
- `data`：repository / datasource
- `domain`：模型与约束
- `ui`：页面与组件编排（通过 DI + Watch 消费状态）

### 5.3 shared

- `theme`：preset + token + 访问扩展
- `widgets`：复用组件（不承担业务依赖装配）

## 6. 核心依赖方向

统一依赖方向如下：

```text
ui -> store -> service/repository
```

约束：

- UI 不直接 new service/repository
- service 不直接读取全局静态对象
- state 不自行 new repository，统一构造注入

## 7. 关键业务流

### 7.1 设置持久化

1. `SettingsRegistry.initialize()`
2. 各 settings store 从 repository hydrate
3. signal 变化触发防抖持久化（300ms）
4. 写入 app support 目录下 JSON

### 7.2 Java 安装/检测

1. `JavaSettingsPage` 调用 `JavaDownloadService`
2. service 更新 `ProgressStore`
3. `RustJavaDownloadDataSource` 调用 FRB
4. Rust 侧执行下载/校验/提取

### 7.3 主题切换

1. UI 修改 `UiSettingsState.themePresetId`
2. `AmlApp` 通过 `Watch` 重建主题
3. 组件通过 `context.tokens` 读取语义颜色

## 8. 已完成的重构点

- 统一 DI 基座与注册顺序
- settings/java/resource/ui store 改为构造注入
- Java 服务去除 `AppStore()` 直连依赖
- 主要 UI 调用切到 `getIt<Store>() + Watch`
- token 旧命名收敛到 `color*` 语义命名
- 文档与结构说明同步到当前实现

## 9. 后续建议

- 增加 settings/repository 与 java service 的单元测试
- 为关键链路补充最小集成回归（主题切换、Java 安装、discover 渲染）
- 持续保持“新增功能必须通过 DI 注入”的代码评审规则
