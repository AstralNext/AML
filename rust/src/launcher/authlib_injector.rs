use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::PathBuf;

const OFFICIAL_META_URL: &str = "https://authlib-injector.yushi.moe/artifact/latest.json";
const BMCLAPI_META_URL: &str =
    "https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/latest.json";
static DOWNLOAD_LOCK: once_cell::sync::Lazy<tokio::sync::Mutex<()>> =
    once_cell::sync::Lazy::new(|| tokio::sync::Mutex::new(()));

#[derive(Debug, Deserialize, Serialize)]
struct ArtifactMetadata {
    version: String,
    download_url: String,
    checksums: ArtifactChecksums,
}

#[derive(Debug, Deserialize, Serialize)]
struct ArtifactChecksums {
    sha256: String,
}

pub async fn ensure_authlib_injector(resource_dir: &str) -> Result<PathBuf> {
    let directory = super::dirs::meta(resource_dir).join("authlib-injector");
    let jar_path = directory.join("authlib-injector.jar");
    if cached_jar_is_valid(&directory, &jar_path).await {
        return Ok(jar_path);
    }
    let _guard = DOWNLOAD_LOCK.lock().await;
    if cached_jar_is_valid(&directory, &jar_path).await {
        return Ok(jar_path);
    }

    tokio::fs::create_dir_all(&directory).await?;
    let client = crate::config::reqwest_builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;
    let metadata = fetch_metadata(&client).await?;
    let bytes = client
        .get(&metadata.download_url)
        .send()
        .await?
        .error_for_status()
        .context("下载 authlib-injector 失败")?
        .bytes()
        .await?;
    let actual = hex::encode(Sha256::digest(&bytes));
    if !actual.eq_ignore_ascii_case(&metadata.checksums.sha256) {
        return Err(anyhow!(
            "authlib-injector SHA-256 校验失败：期望 {}，实际 {}",
            metadata.checksums.sha256,
            actual
        ));
    }

    let temporary = directory.join("authlib-injector.jar.tmp");
    tokio::fs::write(&temporary, &bytes).await?;
    tokio::fs::rename(&temporary, &jar_path).await?;
    tokio::fs::write(
        directory.join("artifact.json"),
        serde_json::to_vec_pretty(&metadata)?,
    )
    .await?;
    Ok(jar_path)
}

async fn cached_jar_is_valid(directory: &std::path::Path, jar_path: &std::path::Path) -> bool {
    let metadata = match tokio::fs::read(directory.join("artifact.json"))
        .await
        .ok()
        .and_then(|bytes| serde_json::from_slice::<ArtifactMetadata>(&bytes).ok())
    {
        Some(metadata) => metadata,
        None => return false,
    };
    let bytes = match tokio::fs::read(jar_path).await {
        Ok(bytes) => bytes,
        Err(_) => return false,
    };
    let actual = hex::encode(Sha256::digest(&bytes));
    actual.eq_ignore_ascii_case(&metadata.checksums.sha256)
}

async fn fetch_metadata(client: &reqwest::Client) -> Result<ArtifactMetadata> {
    let settings = crate::config::cdn_settings();
    let mut urls = vec![OFFICIAL_META_URL.to_string()];
    if settings.bmclapi {
        if settings.official_first {
            urls.push(BMCLAPI_META_URL.to_string());
        } else {
            urls.insert(0, BMCLAPI_META_URL.to_string());
        }
    }
    let mut last_error = None;
    for url in urls {
        match client.get(&url).send().await {
            Ok(response) => match response.error_for_status() {
                Ok(response) => match response.json::<ArtifactMetadata>().await {
                    Ok(metadata) => return Ok(metadata),
                    Err(error) => last_error = Some(error.into()),
                },
                Err(error) => last_error = Some(error.into()),
            },
            Err(error) => last_error = Some(error.into()),
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow!("无法获取 authlib-injector 元数据")))
}
