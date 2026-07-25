use anyhow::{anyhow, Result};
use flutter_rust_bridge::DartFnFuture;
use futures::StreamExt;
use once_cell::sync::Lazy;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json;
use std::collections::HashMap;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};
use sysinfo::System;
use tokio::fs;
use tokio::process::Command;
use zip::ZipArchive;

use crate::config::AZUL_API_BASE_URL;

/// 配置常量
mod config {
    use std::time::Duration;
    /// 下载进度范围
    pub const PROGRESS_DOWNLOAD_START: f64 = 0.2;
    pub const PROGRESS_DOWNLOAD_END: f64 = 0.8;
    pub const PROGRESS_EXTRACT_START: f64 = 0.82;
    pub const PROGRESS_EXTRACT_END: f64 = 0.95;

    /// 超时配置
    pub const HTTP_TIMEOUT: Duration = Duration::from_secs(30);
    pub const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(300);

    /// 重试配置
    pub const MAX_RETRIES: u32 = 3;
    pub const RETRY_DELAY: Duration = Duration::from_secs(2);

    /// 默认内存大小 (8GB in KB)
    pub const DEFAULT_MEMORY_KB: i64 = 8 * 1024 * 1024;

    /// 文件处理批次大小
    pub const FILE_BATCH_SIZE: usize = 10;
}

/// 正则表达式缓存
mod regex_cache {
    use regex::Regex;
    use std::sync::LazyLock;

    /// 缓存的Java版本输出正则表达式
    pub static JAVA_VERSION_OUTPUT_REGEX: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r#"version\s+"([^"]+)""#).unwrap());
}

/// Java 运行时版本信息结构体
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JavaRuntimeVersion {
    pub version: String,
    pub path: String,
    pub major_version: i32,
}

struct CachedJavaRuntime {
    checked_at: Instant,
    file_signature: Option<(u64, SystemTime)>,
    runtime: JavaRuntimeVersion,
}

const JAVA_CHECK_TTL: Duration = Duration::from_secs(10 * 60);
static JAVA_RUNTIME_CACHE: Lazy<Mutex<HashMap<String, CachedJavaRuntime>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Java 下载包信息结构体
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JavaPackage {
    pub download_url: String,
    pub name: String,
}

/// 进度回调函数类型
pub type ProgressCallback = Box<dyn Fn(f64, String) -> DartFnFuture<()> + Send + Sync>;

/// 完成回调函数类型
pub type CompleteCallback = Box<dyn Fn(bool, Option<String>) -> DartFnFuture<()> + Send + Sync>;

/// Azul API 响应结构体
#[derive(Debug, Deserialize)]
struct AzulPackageResponse {
    download_url: String,
    name: String,
}

/// 获取系统架构
fn get_system_arch() -> &'static str {
    if cfg!(target_arch = "x86_64") {
        "x64"
    } else if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x64" // 默认
    }
}

/// 获取系统类型
fn get_system_os() -> Result<&'static str> {
    if cfg!(target_os = "windows") {
        Ok("windows")
    } else if cfg!(target_os = "macos") {
        Ok("macos")
    } else if cfg!(target_os = "linux") {
        Ok("linux")
    } else {
        Err(anyhow!("不支持的操作系统"))
    }
}

/// 从版本字符串中提取主版本号
pub fn extract_java_version(version: &str) -> Result<i32> {
    let version = version.trim().trim_matches('"');
    let base = version.split_once('-').map_or(version, |(value, _)| value);
    let mut parts = base.split('.');

    let first_part = parts
        .next()
        .ok_or_else(|| anyhow!("无法解析 Java 版本: {}", version))?;
    let mut major: i32 = first_part.parse()?;

    if major == 1 {
        let second_part = parts
            .next()
            .ok_or_else(|| anyhow!("无法解析 Java 版本: {}", version))?;
        let minor = second_part
            .split_once('_')
            .map_or(second_part, |(value, _)| value);
        major = minor.parse()?;
    }

    Ok(major)
}

/// 获取可用的 Java 包信息
async fn fetch_java_packages(java_version: i32) -> Result<Vec<JavaPackage>> {
    let client = Client::builder().timeout(config::HTTP_TIMEOUT).build()?;
    let arch = get_system_arch();
    let os = get_system_os()?;

    let url = format!(
        "{}?arch={}&java_version={}&os={}&archive_type=zip&javafx_bundled=false&java_package_type=jre&page_size=1",
        AZUL_API_BASE_URL, arch, java_version, os
    );

    let response = client.get(&url).send().await?;

    if !response.status().is_success() {
        return Err(anyhow!("获取 Java 包信息失败: {}", response.status()));
    }

    let text = response.text().await?;
    let packages: Vec<AzulPackageResponse> = serde_json::from_str(&text)?;

    Ok(packages
        .into_iter()
        .map(|p| JavaPackage {
            download_url: p.download_url,
            name: p.name,
        })
        .collect())
}

/// 下载文件 (流式下载，支持实时进度与自动重试)
async fn download_file(
    url: &str,
    on_progress: Option<&Arc<impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync>>,
) -> Result<Vec<u8>> {
    let client = Client::builder()
        .timeout(config::DOWNLOAD_TIMEOUT)
        .build()?;

    let mut last_err = None;
    for attempt in 1..=config::MAX_RETRIES {
        if attempt > 1 {
            if let Some(callback) = on_progress {
                callback(
                    config::PROGRESS_DOWNLOAD_START,
                    format!(
                        "Retrying download ({attempt}/{})…",
                        config::MAX_RETRIES
                    ),
                )
                .await;
            }
            tokio::time::sleep(config::RETRY_DELAY).await;
        }

        match download_file_once(&client, url, on_progress).await {
            Ok(bytes) => return Ok(bytes),
            Err(e) => {
                last_err = Some(e);
            }
        }
    }

    Err(last_err.unwrap_or_else(|| anyhow!("下载失败")))
}

async fn download_file_once(
    client: &Client,
    url: &str,
    on_progress: Option<&Arc<impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync>>,
) -> Result<Vec<u8>> {
    let response = client.get(url).send().await?;

    if !response.status().is_success() {
        return Err(anyhow!("下载失败: {}", response.status()));
    }

    let content_length = response.content_length().unwrap_or(0);
    let mut bytes = Vec::new();
    let mut downloaded_bytes = 0u64;

    let mut stream = response.bytes_stream();

    while let Some(chunk) = StreamExt::next(&mut stream).await {
        let chunk = chunk?;
        bytes.extend_from_slice(&chunk);
        downloaded_bytes += chunk.len() as u64;

        // 计算下载进度 (使用配置常量)
        if let Some(callback) = on_progress {
            if content_length > 0 {
                let progress = downloaded_bytes as f64 / content_length as f64;
                let progress_range =
                    config::PROGRESS_DOWNLOAD_END - config::PROGRESS_DOWNLOAD_START;
                let overall_progress =
                    config::PROGRESS_DOWNLOAD_START + (progress * progress_range);
                let mb_downloaded = downloaded_bytes as f64 / 1024.0 / 1024.0;
                let mb_total = content_length as f64 / 1024.0 / 1024.0;
                callback(
                    overall_progress,
                    format!("下载中... {:.1}MB / {:.1}MB", mb_downloaded, mb_total),
                )
                .await;
            }
        }
    }

    Ok(bytes)
}

/// 解压ZIP文件
async fn extract_zip(
    zip_data: &[u8],
    extract_to: &Path,
    on_progress: Option<&Arc<impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync>>,
) -> Result<String> {
    use std::io::Read;

    // 先同步解析ZIP文件内容
    let cursor = Cursor::new(zip_data);
    let mut archive = ZipArchive::new(cursor)?;

    let mut root_dir_name = None;
    // (name, data, is_dir, unix_mode)
    let mut file_entries: Vec<(String, Option<Vec<u8>>, bool, Option<u32>)> = Vec::new();
    let total_files = archive.len();

    // 获取根目录名和所有文件信息
    for i in 0..archive.len() {
        let mut file = archive.by_index(i)?;
        let file_name = file.name().to_string();
        let is_dir = file.is_dir();
        let unix_mode = file.unix_mode();

        if is_dir && root_dir_name.is_none() {
            let parts: Vec<&str> = file_name.split('/').collect();
            if !parts.is_empty() && !parts[0].is_empty() {
                root_dir_name = Some(parts[0].to_string());
            }
        }

        if is_dir {
            file_entries.push((file_name, None, true, unix_mode));
        } else {
            let mut buffer = Vec::new();
            file.read_to_end(&mut buffer)?;
            file_entries.push((file_name, Some(buffer), false, unix_mode));
        }
    }

    // 异步创建文件和目录
    for (i, (file_name, data, is_dir, unix_mode)) in file_entries.iter().enumerate() {
        let file_path = extract_to.join(file_name);

        if *is_dir {
            fs::create_dir_all(&file_path).await?;
        } else {
            if let Some(parent) = file_path.parent() {
                fs::create_dir_all(parent).await?;
            }

            if let Some(buffer) = data {
                fs::write(&file_path, buffer).await?;
            }

            #[cfg(unix)]
            {
                apply_extracted_unix_mode(&file_path, *unix_mode).await?;
            }
        }

        // 更新解压进度 (使用配置常量)
        if let Some(callback) = on_progress {
            let progress = (i + 1) as f64 / total_files as f64;
            let progress_range = config::PROGRESS_EXTRACT_END - config::PROGRESS_EXTRACT_START;
            let overall_progress = config::PROGRESS_EXTRACT_START + (progress * progress_range);
            callback(
                overall_progress,
                format!("解压中... {}/{} 文件", i + 1, total_files),
            )
            .await;
        }

        // 每处理指定数量文件就让出控制权
        if (i + 1) % config::FILE_BATCH_SIZE == 0 {
            tokio::task::yield_now().await;
        }
    }

    Ok(root_dir_name.unwrap_or_else(|| "unknown".to_string()))
}

#[cfg(unix)]
async fn apply_extracted_unix_mode(path: &Path, unix_mode: Option<u32>) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let mode = match unix_mode {
        Some(m) if m & 0o111 != 0 => m,
        Some(m) => {
            // ZIP 常丢可执行位；bin/ 与常见辅助二进制补上 +x
            if path_needs_execute_bit(path) {
                m | 0o755
            } else {
                m
            }
        }
        None => {
            if path_needs_execute_bit(path) {
                0o755
            } else {
                return Ok(());
            }
        }
    };

    let perms = std::fs::Permissions::from_mode(mode);
    fs::set_permissions(path, perms).await?;
    Ok(())
}

#[cfg(unix)]
fn path_needs_execute_bit(path: &Path) -> bool {
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    if matches!(
        name,
        "java" | "javac" | "javaw" | "keytool" | "jjs" | "jrunscript" | "jwebserver"
            | "jspawnhelper" | "jexec"
    ) {
        return true;
    }
    path.components().any(|c| c.as_os_str() == "bin")
}

/// Ensure Java home binaries are executable (Linux/macOS ZIP extract safety net).
#[cfg(unix)]
async fn ensure_java_home_executables(java_home: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let mut stack = vec![java_home.join("bin"), java_home.join("lib")];
    while let Some(dir) = stack.pop() {
        if !dir.is_dir() {
            continue;
        }
        let mut rd = fs::read_dir(&dir).await?;
        while let Some(entry) = rd.next_entry().await? {
            let path = entry.path();
            let file_type = entry.file_type().await?;
            if file_type.is_dir() {
                stack.push(path);
                continue;
            }
            if !file_type.is_file() {
                continue;
            }
            if !path_needs_execute_bit(&path) {
                continue;
            }
            let meta = fs::metadata(&path).await?;
            let mut perms = meta.permissions();
            let mode = perms.mode();
            if mode & 0o111 == 0 {
                perms.set_mode(mode | 0o111);
                fs::set_permissions(&path, perms).await?;
            }
        }
    }
    Ok(())
}

#[cfg(not(unix))]
async fn ensure_java_home_executables(_java_home: &Path) -> Result<()> {
    Ok(())
}

/// 获取默认的 Java 安装目录
async fn get_default_java_dir(app_data_dir: &str) -> PathBuf {
    Path::new(app_data_dir).join("java")
}

/// 准备Java安装目录
async fn prepare_java_installation(
    java_version: i32,
    app_data_dir: &str,
    on_progress: &Arc<impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync>,
) -> Result<(PathBuf, JavaPackage)> {
    let java_versions_dir = get_default_java_dir(app_data_dir).await;

    on_progress(0.1, "获取 Java 版本信息".to_string()).await;
    let packages = fetch_java_packages(java_version).await?;

    if packages.is_empty() {
        return Err(anyhow!(
            "未找到 Java {} 版本，系统: {}，架构: {}",
            java_version,
            get_system_os()?,
            get_system_arch()
        ));
    }

    on_progress(0.15, format!("准备下载 Java {}", java_version)).await;
    Ok((java_versions_dir, packages[0].clone()))
}

/// 下载并解压Java包
async fn download_and_extract_java(
    package: &JavaPackage,
    java_versions_dir: &Path,
    java_version: i32,
    on_progress: &Arc<impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync>,
) -> Result<String> {
    // 下载文件
    on_progress(0.2, format!("开始下载 Java {}", java_version)).await;
    let file_bytes = download_file(&package.download_url, Some(on_progress)).await?;

    on_progress(
        config::PROGRESS_EXTRACT_START,
        "下载完成，开始解压 Java".to_string(),
    )
    .await;

    // 创建 Java 版本目录
    fs::create_dir_all(java_versions_dir).await?;

    // 解压 ZIP 文件
    on_progress(0.85, "正在解析压缩文件...".to_string()).await;
    let root_dir_name = extract_zip(&file_bytes, java_versions_dir, Some(on_progress)).await?;

    Ok(root_dir_name)
}

/// 配置Java安装目录
async fn configure_java_installation(
    java_versions_dir: &Path,
    root_dir_name: &str,
    java_version: i32,
    on_progress: &Arc<impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync>,
) -> Result<String> {
    on_progress(0.96, "配置 Java 环境...".to_string()).await;

    // 重命名解压后的目录为 zulu{版本号}
    let target_dir_name = format!("zulu{}", java_version);
    on_progress(0.97, "重命名 Java 目录...".to_string()).await;

    let original_path = java_versions_dir.join(root_dir_name);
    let target_path = java_versions_dir.join(&target_dir_name);

    // 如果目标目录已存在，先删除
    if target_path.exists() {
        fs::remove_dir_all(&target_path).await?;
    }

    // 重命名目录
    if original_path.exists() {
        fs::rename(&original_path, &target_path).await?;
    }

    ensure_java_home_executables(&target_path).await?;

    // 构建 Java 可执行文件路径
    on_progress(0.98, "构建 Java 可执行文件路径...".to_string()).await;

    let java_executable_path = build_java_executable_path(&target_path, java_version);

    on_progress(0.99, "验证安装...".to_string()).await;
    tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;

    on_progress(1.0, format!("Java {} 安装完成！", java_version)).await;
    tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;

    Ok(java_executable_path.to_string_lossy().to_string())
}

/// 构建Java可执行文件路径
fn build_java_executable_path(target_path: &Path, java_version: i32) -> PathBuf {
    if cfg!(target_os = "macos") {
        target_path
            .join(format!("zulu-{}.jre", java_version))
            .join("Contents")
            .join("Home")
            .join("bin")
            .join("java")
    } else {
        // Use java.exe on Windows so launchers can capture stdout/stderr.
        let java_exe_name = if cfg!(target_os = "windows") {
            "java.exe"
        } else {
            "java"
        };
        target_path.join("bin").join(java_exe_name)
    }
}

/// 自动安装 Java (带进度显示)
/// 返回安装路径，如果失败返回 None
pub async fn auto_install_java(
    java_version: i32,
    app_data_dir: String,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
    on_complete: impl Fn(bool, Option<String>) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Option<String> {
    let on_progress = Arc::new(on_progress);
    let on_complete = Arc::new(on_complete);

    let result = auto_install_java_impl(java_version, app_data_dir, &on_progress).await;

    match result {
        Ok(path) => {
            on_complete(true, Some(path.clone())).await;
            Some(path)
        }
        Err(e) => {
            on_complete(false, Some(e.to_string())).await;
            None
        }
    }
}

/// 内部实现函数
async fn auto_install_java_impl(
    java_version: i32,
    app_data_dir: String,
    on_progress: &Arc<impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync>,
) -> Result<String> {
    // 准备安装环境
    let (java_versions_dir, package) =
        prepare_java_installation(java_version, &app_data_dir, on_progress).await?;

    // 下载并解压Java包
    let root_dir_name =
        download_and_extract_java(&package, &java_versions_dir, java_version, on_progress).await?;

    // 配置Java安装
    configure_java_installation(
        &java_versions_dir,
        &root_dir_name,
        java_version,
        on_progress,
    )
    .await
}

/// 检查指定路径的 JRE
pub async fn check_jre(java_path: String) -> Option<JavaRuntimeVersion> {
    match check_jre_impl(&java_path).await {
        Ok(version) => Some(version),
        Err(_) => None,
    }
}

pub(crate) async fn check_jre_impl(java_path: &str) -> Result<JavaRuntimeVersion> {
    let cache_key = java_cache_key(java_path);
    let signature = java_file_signature(java_path);
    if let Some(runtime) = JAVA_RUNTIME_CACHE.lock().ok().and_then(|cache| {
        cache
            .get(&cache_key)
            .filter(|cached| {
                cached.checked_at.elapsed() < JAVA_CHECK_TTL && cached.file_signature == signature
            })
            .map(|cached| cached.runtime.clone())
    }) {
        return Ok(runtime);
    }

    let mut command = Command::new(java_path);
    command.arg("-version");
    crate::launcher::win_process::hide_console_window(&mut command);
    let output = command.output().await?;

    if !output.status.success() {
        return Err(anyhow!("Java 命令执行失败"));
    }

    // Java 版本信息通常在 stderr 中
    let version_output = String::from_utf8_lossy(&output.stderr);

    if let Some(captures) = regex_cache::JAVA_VERSION_OUTPUT_REGEX.captures(&version_output) {
        if let Some(version_match) = captures.get(1) {
            let version = version_match.as_str().to_string();
            let major_version = extract_java_version(&version)?;

            let runtime = JavaRuntimeVersion {
                version,
                path: java_path.to_string(),
                major_version,
            };
            if let Ok(mut cache) = JAVA_RUNTIME_CACHE.lock() {
                cache.insert(
                    cache_key,
                    CachedJavaRuntime {
                        checked_at: Instant::now(),
                        file_signature: signature,
                        runtime: runtime.clone(),
                    },
                );
            }
            return Ok(runtime);
        }
    }

    Err(anyhow!("无法解析 Java 版本信息"))
}

fn java_cache_key(java_path: &str) -> String {
    let canonical = dunce::canonicalize(java_path)
        .unwrap_or_else(|_| PathBuf::from(java_path))
        .to_string_lossy()
        .to_string();
    if cfg!(windows) {
        canonical.to_ascii_lowercase()
    } else {
        canonical
    }
}

fn java_file_signature(java_path: &str) -> Option<(u64, SystemTime)> {
    let metadata = std::fs::metadata(java_path).ok()?;
    Some((metadata.len(), metadata.modified().ok()?))
}

/// 测试指定路径的 JRE 是否符合要求的版本
pub async fn test_jre(java_path: String, expected_major_version: i32) -> bool {
    match check_jre(java_path).await {
        Some(java_version) => java_version.major_version == expected_major_version,
        None => false,
    }
}

/// 检查系统中已安装的 Java
pub async fn check_java_installation() -> Option<JavaRuntimeVersion> {
    check_jre("java".to_string()).await
}

/// 获取系统最大内存 (KB)
pub async fn get_max_memory() -> i64 {
    match get_max_memory_impl().await {
        Ok(memory) => memory,
        Err(_) => config::DEFAULT_MEMORY_KB,
    }
}

async fn get_max_memory_impl() -> Result<i64> {
    // 使用sysinfo库获取系统内存信息，无需调用外部命令
    let mut sys = System::new();
    sys.refresh_memory();

    let total_memory_bytes = sys.total_memory();
    if total_memory_bytes > 0 {
        // sysinfo返回的是字节数，转换为KB
        Ok(total_memory_bytes as i64 / 1024)
    } else {
        Err(anyhow!("无法获取系统内存信息"))
    }
}
