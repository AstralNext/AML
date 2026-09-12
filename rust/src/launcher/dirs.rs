use anyhow::{bail, Result};
use std::path::{Path, PathBuf};

pub const META_DIR: &str = "meta";
pub const INSTANCES_DIR: &str = "instances";
pub const VERSIONS_DIR: &str = "versions";
pub const LIBRARIES_DIR: &str = "libraries";
pub const ASSETS_DIR: &str = "assets";
pub const NATIVES_DIR: &str = "natives";
pub const LOG_CONFIGS_DIR: &str = "log_configs";
pub const JAVA_VERSIONS_DIR: &str = "java_versions";

pub async fn ensure_layout(resource_dir: &str) -> Result<()> {
    let root = PathBuf::from(resource_dir);
    for sub in [
        META_DIR,
        INSTANCES_DIR,
        &format!("{META_DIR}/{VERSIONS_DIR}"),
        &format!("{META_DIR}/{LIBRARIES_DIR}"),
        &format!("{META_DIR}/{ASSETS_DIR}"),
        &format!("{META_DIR}/{ASSETS_DIR}/indexes"),
        &format!("{META_DIR}/{ASSETS_DIR}/objects"),
        &format!("{META_DIR}/resources"),
        &format!("{META_DIR}/{NATIVES_DIR}"),
        &format!("{META_DIR}/{LOG_CONFIGS_DIR}"),
        &format!("{META_DIR}/{JAVA_VERSIONS_DIR}"),
        &format!("{META_DIR}/launcher"),
    ] {
        tokio::fs::create_dir_all(root.join(sub)).await?;
    }
    Ok(())
}

pub fn meta(resource_dir: &str) -> PathBuf {
    PathBuf::from(resource_dir).join(META_DIR)
}

pub fn libraries(resource_dir: &str) -> PathBuf {
    meta(resource_dir).join(LIBRARIES_DIR)
}

pub fn assets(resource_dir: &str) -> PathBuf {
    meta(resource_dir).join(ASSETS_DIR)
}

/// Flat virtual paths for `assets: "legacy"` versions (`meta/resources/`).
pub fn legacy_assets(resource_dir: &str) -> PathBuf {
    meta(resource_dir).join("resources")
}

pub fn versions(resource_dir: &str) -> PathBuf {
    meta(resource_dir).join(VERSIONS_DIR)
}

pub fn natives(resource_dir: &str, version_id: &str) -> PathBuf {
    meta(resource_dir).join(NATIVES_DIR).join(version_id)
}

pub fn log_configs(resource_dir: &str) -> PathBuf {
    meta(resource_dir).join(LOG_CONFIGS_DIR)
}

pub fn instance_dir(resource_dir: &str, path: &str) -> PathBuf {
    PathBuf::from(resource_dir).join(INSTANCES_DIR).join(path)
}

pub async fn ensure_instance_dir(resource_dir: &str, path: &str) -> Result<PathBuf> {
    let dir = instance_dir(resource_dir, path);
    tokio::fs::create_dir_all(&dir).await?;
    for sub in [
        "mods",
        "resourcepacks",
        "shaderpacks",
        "datapacks",
        "saves",
        "logs",
    ] {
        tokio::fs::create_dir_all(dir.join(sub)).await?;
    }
    Ok(dir)
}

pub async fn copy_dir_all(src: &Path, dst: &Path) -> Result<()> {
    if !src.exists() {
        return Ok(());
    }
    tokio::fs::create_dir_all(dst).await?;
    let mut entries = tokio::fs::read_dir(src).await?;
    while let Some(entry) = entries.next_entry().await? {
        let file_type = entry.file_type().await?;
        let dest = dst.join(entry.file_name());
        if file_type.is_dir() {
            Box::pin(copy_dir_all(&entry.path(), &dest)).await?;
        } else {
            tokio::fs::copy(entry.path(), &dest).await?;
        }
    }
    Ok(())
}

/// Resolve a configured Java path to the `java` executable.
///
/// Accepted inputs:
/// - absolute path to `java` / `java.exe`
/// - JDK/JRE home directory containing `bin/java[.exe]`
pub fn java_executable(java_path: &str) -> Result<PathBuf> {
    let trimmed = java_path.trim();
    if trimmed.is_empty() {
        bail!("Java 路径为空");
    }

    let path = PathBuf::from(trimmed);
    if is_java_executable(&path) {
        return Ok(path);
    }

    let from_home = path.join("bin").join(java_file_name());
    if is_java_executable(&from_home) {
        return Ok(from_home);
    }

    bail!(
        "无效的 Java 路径: {trimmed}（需要 java 可执行文件，或包含 bin/{} 的 JDK/JRE 目录）",
        java_file_name()
    )
}

fn java_file_name() -> &'static str {
    if cfg!(windows) {
        "java.exe"
    } else {
        "java"
    }
}

fn is_java_executable(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    path.file_name()
        .map(|name| {
            let name = name.to_string_lossy();
            name.eq_ignore_ascii_case("java") || name.eq_ignore_ascii_case("java.exe")
        })
        .unwrap_or(false)
}
