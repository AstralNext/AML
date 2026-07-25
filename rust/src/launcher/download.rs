use anyhow::{anyhow, Context, Result};
use futures::stream::{FuturesUnordered, StreamExt};
use reqwest::Client;
use sha1::{Digest, Sha1};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Semaphore;

use crate::meta::minecraft::{
    get_path_from_artifact, AssetsIndex, DownloadType, Library, LoggingConfiguration, LoggingSide,
    VersionInfo,
};

use super::dirs;
use super::rules::{parse_rules, RuleFeatures};

pub type ProgressFn = Arc<dyn Fn(f64, String) + Send + Sync>;

/// Total attempts per URL (initial try + retries), matching Modrinth-style resilience.
pub const DOWNLOAD_ATTEMPTS: u32 = 3;

/// Concurrent file downloads for modpack / content packs (not per-file chunking).
pub const PACK_DOWNLOAD_CONCURRENCY: usize = 32;

/// TCP connect timeout for launcher HTTP clients.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

/// Max wait for response headers on a download.
pub const DOWNLOAD_HEADER_TIMEOUT: Duration = Duration::from_secs(60);

/// Abort if no body bytes arrive for this long (stalled transfer).
pub const DOWNLOAD_IDLE_TIMEOUT: Duration = Duration::from_secs(90);

/// Absolute upper bound for any single HTTP request (safety net).
pub const REQUEST_OVERALL_TIMEOUT: Duration = Duration::from_secs(30 * 60);

pub(crate) fn sha1_hex(data: &[u8]) -> String {
    let mut hasher = Sha1::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}

pub(crate) async fn sha1_file(path: &Path) -> Result<String> {
    use tokio::io::AsyncReadExt;
    let mut file = tokio::fs::File::open(path)
        .await
        .with_context(|| format!("open for sha1 {}", path.display()))?;
    let mut hasher = Sha1::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = file.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

/// True when [dest] exists and optionally matches [expected_sha1] (case-insensitive).
/// Empty / missing expected hash → any non-empty existing file counts as OK.
pub(crate) async fn file_already_ok(dest: &Path, expected_sha1: Option<&str>) -> bool {
    if !dest.exists() {
        return false;
    }
    let Ok(meta) = tokio::fs::metadata(dest).await else {
        return false;
    };
    if meta.len() == 0 {
        return false;
    }
    match expected_sha1.map(str::trim).filter(|s| !s.is_empty()) {
        None => true,
        Some(expected) => match sha1_file(dest).await {
            Ok(actual) => actual.eq_ignore_ascii_case(expected),
            Err(_) => false,
        },
    }
}

async fn download_checked_once(
    client: &Client,
    url: &str,
    expected_sha1: Option<&str>,
) -> Result<Vec<u8>> {
    let bytes = fetch_bytes_with_timeout(client, url, None).await?;
    if let Some(expected) = expected_sha1 {
        let actual = sha1_hex(&bytes);
        if !expected.is_empty() && actual != expected {
            anyhow::bail!("sha1 mismatch for {url}: expected {expected}, got {actual}");
        }
    }
    Ok(bytes)
}

/// GET [url] with header + idle-body timeouts. Optional extra headers (e.g. CF API key).
pub(crate) async fn fetch_bytes_with_timeout(
    client: &Client,
    url: &str,
    extra_headers: Option<&[(&str, &str)]>,
) -> Result<Vec<u8>> {
    let mut req = client.get(url);
    if let Some(headers) = extra_headers {
        for (k, v) in headers {
            req = req.header(*k, *v);
        }
    }
    let resp = tokio::time::timeout(DOWNLOAD_HEADER_TIMEOUT, req.send())
        .await
        .map_err(|_| anyhow!("下载连接超时（{DOWNLOAD_HEADER_TIMEOUT:?}）: {url}"))?
        .with_context(|| format!("请求失败: {url}"))?
        .error_for_status()
        .with_context(|| format!("HTTP 错误: {url}"))?;
    read_body_with_idle_timeout(resp, DOWNLOAD_IDLE_TIMEOUT)
        .await
        .with_context(|| format!("下载中断: {url}"))
}

/// Read response body; fail if no chunk arrives within [idle].
pub(crate) async fn read_body_with_idle_timeout(
    response: reqwest::Response,
    idle: Duration,
) -> Result<Vec<u8>> {
    use futures::StreamExt;
    let mut stream = response.bytes_stream();
    let mut buf = Vec::new();
    loop {
        match tokio::time::timeout(idle, stream.next()).await {
            Ok(Some(Ok(chunk))) => buf.extend_from_slice(&chunk),
            Ok(Some(Err(e))) => return Err(e.into()),
            Ok(None) => break,
            Err(_) => {
                anyhow::bail!("下载停滞：{idle:?} 内未收到数据");
            }
        }
    }
    Ok(buf)
}

/// Download with checksum validation and automatic retries.
///
/// [on_retry] is invoked before sleep when attempt `n` failed and we will try
/// again; arguments are `(next_attempt, max_attempts)`.
pub(crate) async fn download_checked_with_retry(
    client: &Client,
    url: &str,
    expected_sha1: Option<&str>,
    on_retry: Option<&(dyn Fn(u32, u32) + Send + Sync)>,
) -> Result<Vec<u8>> {
    let mut last_err = None;
    for attempt in 1..=DOWNLOAD_ATTEMPTS {
        match download_checked_once(client, url, expected_sha1).await {
            Ok(bytes) => return Ok(bytes),
            Err(e) => {
                last_err = Some(e);
                if attempt < DOWNLOAD_ATTEMPTS {
                    if let Some(cb) = on_retry {
                        cb(attempt + 1, DOWNLOAD_ATTEMPTS);
                    }
                    tokio::time::sleep(Duration::from_millis(250 * attempt as u64)).await;
                }
            }
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("download failed for {url}")))
}

/// Try official URL then MCIM CDN mirror (each with retries).
pub(crate) async fn download_checked_with_mcim_fallback(
    client: &Client,
    url: &str,
    expected_sha1: Option<&str>,
    on_retry: Option<&(dyn Fn(u32, u32) + Send + Sync)>,
) -> Result<Vec<u8>> {
    let mut last_err = None;
    for candidate in crate::config::mcim_url_candidates(url) {
        match download_checked_with_retry(client, &candidate, expected_sha1, on_retry).await {
            Ok(bytes) => return Ok(bytes),
            Err(e) => last_err = Some(e),
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("download failed for {url}")))
}

/// Download raw bytes with optional headers, trying MCIM CDN after the official URL.
pub(crate) async fn fetch_bytes_with_mcim_fallback(
    client: &Client,
    url: &str,
    extra_headers: Option<&[(&str, &str)]>,
) -> Result<Vec<u8>> {
    let mut last_err = None;
    for candidate in crate::config::mcim_url_candidates(url) {
        match fetch_bytes_with_timeout(client, &candidate, extra_headers).await {
            Ok(bytes) => return Ok(bytes),
            Err(e) => last_err = Some(e),
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("download failed: {url}")))
}

async fn download_checked(
    client: &Client,
    url: &str,
    expected_sha1: Option<&str>,
) -> Result<Vec<u8>> {
    download_checked_with_retry(client, url, expected_sha1, None).await
}

async fn try_download_checked(
    client: &Client,
    url: &str,
    expected_sha1: Option<&str>,
) -> Result<Option<Vec<u8>>> {
    match download_checked(client, url, expected_sha1).await {
        Ok(bytes) => Ok(Some(bytes)),
        Err(err) => {
            tracing::debug!("optional library download failed for {url}: {err:#}");
            Ok(None)
        }
    }
}

fn arch_width(java_arch: &str) -> &'static str {
    if java_arch == "x86" {
        "32"
    } else {
        "64"
    }
}

fn parsed_native_classifier(os_key: &str, java_arch: &str) -> String {
    os_key.replace("${arch}", arch_width(java_arch))
}

async fn library_file_cached(dest: &Path, expected_sha: &str) -> bool {
    if !dest.exists() {
        return false;
    }
    if expected_sha.is_empty() {
        return true;
    }
    if let Ok(existing) = tokio::fs::read(dest).await {
        return sha1_hex(&existing) == expected_sha;
    }
    false
}

async fn write_library_file(
    client: &Client,
    dest: &Path,
    url: &str,
    expected_sha: &str,
    required: bool,
    on_progress: Option<&ProgressFn>,
    progress_value: f64,
) -> Result<()> {
    if library_file_cached(dest, expected_sha).await {
        return Ok(());
    }
    let sha = if expected_sha.is_empty() {
        None
    } else {
        Some(expected_sha)
    };
    let on_retry = |attempt: u32, max: u32| {
        if let Some(cb) = on_progress {
            cb(
                progress_value,
                format!("Retrying download ({attempt}/{max})…"),
            );
        }
    };
    let bytes = if required {
        download_checked_with_retry(client, url, sha, Some(&on_retry)).await?
    } else if let Some(bytes) = try_download_checked(client, url, sha).await? {
        bytes
    } else {
        return Ok(());
    };
    write_file(dest, &bytes).await?;
    Ok(())
}

async fn write_file(path: &Path, data: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    tokio::fs::write(path, data).await?;
    Ok(())
}

fn library_path(lib: &Library) -> Result<String> {
    if let Some(downloads) = &lib.downloads {
        if let Some(artifact) = &downloads.artifact {
            if let Some(path) = &artifact.path {
                return Ok(path.clone());
            }
        }
    }
    get_path_from_artifact(&lib.name)
}

fn library_url(lib: &Library, path: &str) -> Result<String> {
    if let Some(downloads) = &lib.downloads {
        if let Some(artifact) = &downloads.artifact {
            return Ok(artifact.url.clone());
        }
    }
    let base = lib
        .url
        .clone()
        .unwrap_or_else(|| "https://libraries.minecraft.net/".into());
    let base = if base.ends_with('/') {
        base
    } else {
        format!("{base}/")
    };
    Ok(format!("{base}{path}"))
}

pub async fn download_minecraft(
    resource_dir: &str,
    info: &VersionInfo,
    version_jar_id: &str,
    java_arch: &str,
    on_progress: Option<ProgressFn>,
) -> Result<()> {
    let client = super::manifest::http_client()?;
    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    report(0.05, "Downloading client…".into());
    download_client(&client, resource_dir, info, version_jar_id, &on_progress).await?;

    report(0.15, "Downloading libraries…".into());
    download_libraries(&client, resource_dir, info, java_arch, &on_progress).await?;

    report(0.55, "Extracting natives…".into());
    extract_natives(
        &client,
        resource_dir,
        info,
        version_jar_id,
        java_arch,
        &on_progress,
    )
    .await?;

    report(0.65, "Downloading assets…".into());
    download_assets(
        &client,
        resource_dir,
        info.assets == "legacy",
        info,
        &on_progress,
    )
    .await?;

    report(0.95, "Downloading log config…".into());
    download_log_config(&client, resource_dir, info, &on_progress).await?;

    report(1.0, "Download complete".into());
    Ok(())
}

async fn download_client(
    client: &Client,
    resource_dir: &str,
    info: &VersionInfo,
    version_jar_id: &str,
    on_progress: &Option<ProgressFn>,
) -> Result<()> {
    let download = info
        .downloads
        .get(&DownloadType::Client)
        .ok_or_else(|| anyhow!("version has no client download"))?;
    let dest = dirs::versions(resource_dir)
        .join(version_jar_id)
        .join(format!("{version_jar_id}.jar"));
    if dest.exists() {
        let existing = tokio::fs::read(&dest).await?;
        if sha1_hex(&existing) == download.sha1 {
            return Ok(());
        }
    }
    let on_retry = |attempt: u32, max: u32| {
        if let Some(cb) = on_progress {
            cb(0.05, format!("Retrying download ({attempt}/{max})…"));
        }
    };
    let bytes =
        download_checked_with_retry(client, &download.url, Some(&download.sha1), Some(&on_retry))
            .await?;
    write_file(&dest, &bytes).await?;
    Ok(())
}

async fn download_libraries(
    client: &Client,
    resource_dir: &str,
    info: &VersionInfo,
    java_arch: &str,
    on_progress: &Option<ProgressFn>,
) -> Result<()> {
    let libs_root = dirs::libraries(resource_dir);
    let libs: Vec<&Library> = info
        .libraries
        .iter()
        .filter(|lib| {
            parse_rules(
                lib.rules.as_deref().unwrap_or(&[]),
                java_arch,
                RuleFeatures::default(),
            ) && lib.downloadable
        })
        .collect();

    let total = libs.len().max(1) as f64;
    let sem = Arc::new(Semaphore::new(32));
    let mut futs = FuturesUnordered::new();

    for (i, lib) in libs.into_iter().enumerate() {
        let client = client.clone();
        let sem = sem.clone();
        let on_progress = on_progress.clone();
        let libs_root = libs_root.clone();
        let lib = lib.clone();
        futs.push(async move {
            let _permit = sem.acquire().await.ok();
            download_one_library(
                &client,
                &libs_root,
                &lib,
                java_arch,
                on_progress.as_ref(),
                i,
                total,
            )
            .await?;
            Ok::<(), anyhow::Error>(())
        });
    }

    while let Some(res) = futs.next().await {
        res?;
    }
    Ok(())
}

async fn download_one_library(
    client: &Client,
    libs_root: &Path,
    lib: &Library,
    java_arch: &str,
    on_progress: Option<&ProgressFn>,
    index: usize,
    total: f64,
) -> Result<()> {
    let progress_value = 0.15 + (index as f64 / total) * 0.35;
    // Libraries with natives only: fetch the native jar.
    if let Some((os_key, classifiers)) = lib.natives_os_key_and_classifiers(java_arch) {
        let classifier = parsed_native_classifier(os_key, java_arch);
        let Some(native) = classifiers.get(&classifier) else {
            return Ok(());
        };
        let path = native.path.clone().unwrap_or_else(|| {
            get_path_from_artifact(&format!("{}:{classifier}", lib.name)).unwrap_or_default()
        });
        let dest = libs_root.join(&path);
        write_library_file(
            client,
            &dest,
            &native.url,
            &native.sha1,
            true,
            on_progress,
            progress_value,
        )
        .await?;
    } else {
        let path = library_path(lib)?;
        let dest = libs_root.join(&path);
        let expected_sha = lib
            .downloads
            .as_ref()
            .and_then(|d| d.artifact.as_ref())
            .map(|a| a.sha1.clone())
            .unwrap_or_default();

        if let Some(artifact) = lib
            .downloads
            .as_ref()
            .and_then(|d| d.artifact.as_ref())
            .filter(|a| !a.url.is_empty())
        {
            write_library_file(
                client,
                &dest,
                &artifact.url,
                &expected_sha,
                true,
                on_progress,
                progress_value,
            )
            .await?;
        } else {
            let url = library_url(lib, &path)?;
            write_library_file(
                client,
                &dest,
                &url,
                &expected_sha,
                false,
                on_progress,
                progress_value,
            )
            .await?;
        }
    }

    if let Some(cb) = on_progress {
        cb(progress_value, format!("Library {}", lib.name));
    }
    Ok(())
}

async fn extract_natives(
    client: &Client,
    resource_dir: &str,
    info: &VersionInfo,
    version_jar_id: &str,
    java_arch: &str,
    on_progress: &Option<ProgressFn>,
) -> Result<()> {
    let natives_dir = dirs::natives(resource_dir, version_jar_id);
    tokio::fs::create_dir_all(&natives_dir).await?;
    let libs_root = dirs::libraries(resource_dir);

    for lib in &info.libraries {
        if !parse_rules(
            lib.rules.as_deref().unwrap_or(&[]),
            java_arch,
            RuleFeatures::default(),
        ) {
            continue;
        }
        let Some((os_key, classifiers)) = lib.natives_os_key_and_classifiers(java_arch) else {
            continue;
        };
        let classifier = parsed_native_classifier(os_key, java_arch);
        let Some(native) = classifiers.get(&classifier) else {
            continue;
        };
        let path = native.path.clone().unwrap_or_else(|| {
            get_path_from_artifact(&format!("{}:{classifier}", {
                let parts: Vec<_> = lib.name.split(':').collect();
                if parts.len() >= 3 {
                    format!("{}:{}:{}", parts[0], parts[1], parts[2])
                } else {
                    lib.name.clone()
                }
            }))
            .unwrap_or_default()
        });
        let jar_path = libs_root.join(&path);
        if !jar_path.exists() {
            let on_retry = |attempt: u32, max: u32| {
                if let Some(cb) = on_progress {
                    cb(0.55, format!("Retrying download ({attempt}/{max})…"));
                }
            };
            let bytes = download_checked_with_retry(
                client,
                &native.url,
                Some(&native.sha1),
                Some(&on_retry),
            )
            .await?;
            write_file(&jar_path, &bytes).await?;
        }
        extract_zip_natives(
            &jar_path,
            &natives_dir,
            lib.extract.as_ref().and_then(|e| e.exclude.as_ref()),
        )?;
    }
    Ok(())
}

fn extract_zip_natives(jar: &Path, dest: &Path, exclude: Option<&Vec<String>>) -> Result<()> {
    let file = std::fs::File::open(jar)?;
    let mut archive = zip::ZipArchive::new(file)?;
    for i in 0..archive.len() {
        let mut file = archive.by_index(i)?;
        let name = file.name().to_string();
        if name.ends_with('/') {
            continue;
        }
        if let Some(ex) = exclude {
            if ex.iter().any(|e| name.starts_with(e)) {
                continue;
            }
        }
        let out = dest.join(Path::new(&name).file_name().unwrap_or_default());
        let mut outfile = std::fs::File::create(&out)?;
        std::io::copy(&mut file, &mut outfile)?;
    }
    Ok(())
}

async fn download_assets(
    client: &Client,
    resource_dir: &str,
    with_legacy: bool,
    info: &VersionInfo,
    on_progress: &Option<ProgressFn>,
) -> Result<()> {
    let index_path = dirs::assets(resource_dir)
        .join("indexes")
        .join(format!("{}.json", info.asset_index.id));
    let index_bytes = if index_path.exists() {
        tokio::fs::read(&index_path).await?
    } else {
        let on_retry = |attempt: u32, max: u32| {
            if let Some(cb) = on_progress {
                cb(0.65, format!("Retrying download ({attempt}/{max})…"));
            }
        };
        let bytes = download_checked_with_retry(
            client,
            &info.asset_index.url,
            Some(&info.asset_index.sha1),
            Some(&on_retry),
        )
        .await?;
        write_file(&index_path, &bytes).await?;
        bytes
    };
    let index: AssetsIndex = serde_json::from_slice(&index_bytes)?;

    let entries: Vec<(String, crate::meta::minecraft::Asset)> = index.objects.into_iter().collect();
    let total = entries.len().max(1) as f64;
    let sem = Arc::new(Semaphore::new(64));
    let mut futs = FuturesUnordered::new();
    let objects_root = dirs::assets(resource_dir).join("objects");
    let legacy_root = dirs::legacy_assets(resource_dir);

    for (i, (name, asset)) in entries.into_iter().enumerate() {
        let client = client.clone();
        let sem = sem.clone();
        let on_progress = on_progress.clone();
        let objects_root = objects_root.clone();
        let legacy_root = legacy_root.clone();
        futs.push(async move {
            let _permit = sem.acquire().await.ok();
            let prefix = &asset.hash[..2.min(asset.hash.len())];
            let object_dest = objects_root.join(prefix).join(&asset.hash);
            let url = format!(
                "https://resources.download.minecraft.net/{prefix}/{}",
                asset.hash
            );

            let needs_object = !object_dest.exists();
            let legacy_dest = legacy_root.join(name.replace('/', std::path::MAIN_SEPARATOR_STR));
            let needs_legacy = with_legacy && !legacy_dest.exists();

            if !needs_object && !needs_legacy {
                return Ok::<(), anyhow::Error>(());
            }

            let bytes = if object_dest.exists() && !needs_object {
                tokio::fs::read(&object_dest).await?
            } else {
                let progress_value = 0.65 + (i as f64 / total) * 0.25;
                let on_retry = |attempt: u32, max: u32| {
                    if let Some(cb) = &on_progress {
                        cb(
                            progress_value,
                            format!("Retrying download ({attempt}/{max})…"),
                        );
                    }
                };
                download_checked_with_retry(&client, &url, Some(&asset.hash), Some(&on_retry))
                    .await?
            };

            if needs_object || !object_dest.exists() {
                write_file(&object_dest, &bytes).await?;
            }
            if needs_legacy {
                if let Some(parent) = legacy_dest.parent() {
                    tokio::fs::create_dir_all(parent).await?;
                }
                write_file(&legacy_dest, &bytes).await?;
            }

            if let Some(cb) = &on_progress {
                if i % 50 == 0 {
                    cb(
                        0.65 + (i as f64 / total) * 0.25,
                        format!("Assets {i}/{}", total as u64),
                    );
                }
            }
            Ok(())
        });
    }

    while let Some(res) = futs.next().await {
        res?;
    }
    Ok(())
}

async fn download_log_config(
    client: &Client,
    resource_dir: &str,
    info: &VersionInfo,
    on_progress: &Option<ProgressFn>,
) -> Result<()> {
    let Some(logging) = &info.logging else {
        return Ok(());
    };
    let Some(LoggingConfiguration::Log4j2Xml { file, .. }) = logging.get(&LoggingSide::Client)
    else {
        return Ok(());
    };
    let dest = dirs::log_configs(resource_dir).join(&file.id);
    if dest.exists() {
        return Ok(());
    }
    let on_retry = |attempt: u32, max: u32| {
        if let Some(cb) = on_progress {
            cb(0.95, format!("Retrying download ({attempt}/{max})…"));
        }
    };
    let bytes =
        download_checked_with_retry(client, &file.url, Some(&file.sha1), Some(&on_retry)).await?;
    write_file(&dest, &bytes).await?;
    Ok(())
}

pub fn client_jar_path(resource_dir: &str, version_jar_id: &str) -> PathBuf {
    dirs::versions(resource_dir)
        .join(version_jar_id)
        .join(format!("{version_jar_id}.jar"))
}
