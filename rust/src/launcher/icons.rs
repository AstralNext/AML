use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

use crate::state::db;

use super::download;

pub fn icons_cache_dir(resource_dir: &str) -> PathBuf {
    PathBuf::from(resource_dir).join("cache").join("icons")
}

/// Write icon bytes to `{resource_dir}/cache/icons/{sha1}.{ext}`.
pub async fn write_cached_icon(resource_dir: &str, hint: &str, bytes: &[u8]) -> Result<String> {
    let dir = icons_cache_dir(resource_dir);
    tokio::fs::create_dir_all(&dir).await?;
    let ext = Path::new(hint)
        .extension()
        .and_then(|e| e.to_str())
        .filter(|e| !e.is_empty())
        .unwrap_or("png");
    let hash = download::sha1_hex(bytes);
    let path = dir.join(format!("{hash}.{ext}"));
    if !path.exists() {
        tokio::fs::write(&path, bytes).await?;
    }
    Ok(path.to_string_lossy().to_string())
}

/// Cache a local file or remote URL and return the cached absolute path.
pub async fn resolve_icon_source(resource_dir: &str, source: &str) -> Result<Option<String>> {
    let trimmed = source.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }

    let bytes = if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        let client = super::manifest::http_client()?;
        client
            .get(trimmed)
            .send()
            .await?
            .error_for_status()?
            .bytes()
            .await?
            .to_vec()
    } else {
        tokio::fs::read(trimmed)
            .await
            .with_context(|| format!("read icon file {trimmed}"))?
    };

    let hint = if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.rsplit('/').next().unwrap_or("icon.png")
    } else {
        trimmed
    };

    Ok(Some(write_cached_icon(resource_dir, hint, &bytes).await?))
}

pub async fn resolve_icon_from_path(resource_dir: &str, path: &Path) -> Result<Option<String>> {
    if !path.exists() {
        return Ok(None);
    }
    resolve_icon_source(resource_dir, &path.to_string_lossy()).await
}

pub async fn set_instance_icon(
    pool: &sqlx::SqlitePool,
    instance_id: &str,
    icon_path: Option<String>,
) -> Result<()> {
    db::set_instance_icon(pool, instance_id, icon_path).await
}
