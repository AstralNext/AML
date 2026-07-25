use anyhow::{anyhow, Context, Result};
use once_cell::sync::Lazy;
use reqwest::Client;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::RwLock;
use std::time::{Duration, Instant, SystemTime};

use crate::config::META_URL;
use crate::meta::minecraft::{VersionInfo, VersionManifest, CURRENT_FORMAT_VERSION};
use crate::meta::modded::{
    loader_meta_path, merge_partial_version, LoaderVersion, Manifest as LoaderManifest,
    PartialVersionInfo, DUMMY_REPLACE_STRING,
};
use crate::state::models::ModLoader;

use super::dirs;

const MANIFEST_TTL: Duration = Duration::from_secs(6 * 60 * 60);

static HTTP_CLIENT: Lazy<Client> = Lazy::new(|| {
    Client::builder()
        .user_agent("AstralMinecraftLauncher/0.1")
        .gzip(true)
        .connect_timeout(super::download::CONNECT_TIMEOUT)
        .timeout(super::download::REQUEST_OVERALL_TIMEOUT)
        .build()
        .expect("build HTTP client")
});
static MINECRAFT_MANIFEST_CACHE: Lazy<RwLock<HashMap<PathBuf, (Instant, VersionManifest)>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));
static LOADER_MANIFEST_CACHE: Lazy<RwLock<HashMap<PathBuf, (Instant, LoaderManifest)>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));
static VERSION_INFO_CACHE: Lazy<RwLock<HashMap<PathBuf, VersionInfo>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));

pub fn http_client() -> Result<Client> {
    Ok(HTTP_CLIENT.clone())
}

pub async fn fetch_minecraft_manifest(resource_dir: &str) -> Result<VersionManifest> {
    let cache_path = dirs::meta(resource_dir).join("minecraft_manifest.json");
    if let Some(manifest) = cached_minecraft_manifest(&cache_path) {
        return Ok(manifest);
    }
    let disk = read_json_cache::<VersionManifest>(&cache_path).await;
    if cache_is_fresh(&cache_path).await {
        if let Some(manifest) = disk.as_ref() {
            let manifest = manifest.clone();
            store_minecraft_manifest(cache_path, manifest.clone());
            return Ok(manifest);
        }
    }
    let url = format!("{META_URL}minecraft/v{CURRENT_FORMAT_VERSION}/manifest.json");
    let client = http_client()?;
    let remote = async {
        let response = client.get(&url).send().await?.error_for_status()?;
        response.text().await
    }
    .await;
    match remote {
        Ok(text) => {
            let manifest: VersionManifest = serde_json::from_str(&text)?;
            tokio::fs::write(&cache_path, &text).await.ok();
            store_minecraft_manifest(cache_path, manifest.clone());
            Ok(manifest)
        }
        Err(error) => disk.ok_or_else(|| error.into()),
    }
}

/// Launches should never wait on metadata refresh when a valid installed cache exists.
pub async fn load_cached_minecraft_manifest(resource_dir: &str) -> Result<VersionManifest> {
    let cache_path = dirs::meta(resource_dir).join("minecraft_manifest.json");
    if let Some(manifest) = MINECRAFT_MANIFEST_CACHE
        .read()
        .ok()
        .and_then(|cache| cache.get(&cache_path).map(|(_, manifest)| manifest.clone()))
    {
        return Ok(manifest);
    }
    let manifest = read_json_cache::<VersionManifest>(&cache_path)
        .await
        .with_context(|| format!("missing Minecraft manifest at {}", cache_path.display()))?;
    store_minecraft_manifest(cache_path, manifest.clone());
    Ok(manifest)
}

pub async fn list_game_versions(resource_dir: &str) -> Result<Vec<GameVersionDto>> {
    let manifest = fetch_minecraft_manifest(resource_dir).await?;
    Ok(manifest
        .versions
        .into_iter()
        .map(|v| GameVersionDto {
            id: v.id,
            type_: v.type_.as_str().to_string(),
            url: v.url,
            release_time: v.release_time.to_rfc3339(),
        })
        .collect())
}

#[derive(Clone, Debug)]
pub struct GameVersionDto {
    pub id: String,
    pub type_: String,
    pub url: String,
    pub release_time: String,
}

pub async fn fetch_loader_manifest(
    resource_dir: &str,
    loader: &ModLoader,
) -> Result<LoaderManifest> {
    if matches!(loader, ModLoader::Vanilla) {
        return Ok(LoaderManifest {
            game_versions: vec![],
        });
    }
    let path = loader_meta_path(loader.as_meta_str());
    let url = format!("{META_URL}{path}");
    let cache = dirs::meta(resource_dir).join(format!("{}_manifest.json", loader.as_meta_str()));
    if let Some(manifest) = cached_loader_manifest(&cache) {
        return Ok(manifest);
    }
    let disk = read_json_cache::<LoaderManifest>(&cache).await;
    if cache_is_fresh(&cache).await {
        if let Some(manifest) = disk.as_ref() {
            let manifest = manifest.clone();
            store_loader_manifest(cache, manifest.clone());
            return Ok(manifest);
        }
    }
    let client = http_client()?;
    let remote = async {
        let response = client.get(&url).send().await?.error_for_status()?;
        response.text().await
    }
    .await;
    match remote {
        Ok(text) => {
            let manifest: LoaderManifest = serde_json::from_str(&text)?;
            tokio::fs::write(&cache, &text).await.ok();
            store_loader_manifest(cache, manifest.clone());
            Ok(manifest)
        }
        Err(error) => disk.ok_or_else(|| error.into()),
    }
}

fn cached_minecraft_manifest(path: &Path) -> Option<VersionManifest> {
    MINECRAFT_MANIFEST_CACHE
        .read()
        .ok()?
        .get(path)
        .filter(|(loaded, _)| loaded.elapsed() < MANIFEST_TTL)
        .map(|(_, manifest)| manifest.clone())
}

fn store_minecraft_manifest(path: PathBuf, manifest: VersionManifest) {
    if let Ok(mut cache) = MINECRAFT_MANIFEST_CACHE.write() {
        cache.insert(path, (Instant::now(), manifest));
    }
}

fn cached_loader_manifest(path: &Path) -> Option<LoaderManifest> {
    LOADER_MANIFEST_CACHE
        .read()
        .ok()?
        .get(path)
        .filter(|(loaded, _)| loaded.elapsed() < MANIFEST_TTL)
        .map(|(_, manifest)| manifest.clone())
}

fn store_loader_manifest(path: PathBuf, manifest: LoaderManifest) {
    if let Ok(mut cache) = LOADER_MANIFEST_CACHE.write() {
        cache.insert(path, (Instant::now(), manifest));
    }
}

async fn read_json_cache<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    let text = tokio::fs::read_to_string(path).await.ok()?;
    serde_json::from_str(&text).ok()
}

async fn cache_is_fresh(path: &Path) -> bool {
    let modified = match tokio::fs::metadata(path)
        .await
        .and_then(|meta| meta.modified())
    {
        Ok(modified) => modified,
        Err(_) => return false,
    };
    SystemTime::now()
        .duration_since(modified)
        .map(|age| age < MANIFEST_TTL)
        .unwrap_or(false)
}

pub async fn list_loader_versions(
    resource_dir: &str,
    loader: &ModLoader,
    game_version: &str,
) -> Result<Vec<LoaderVersionDto>> {
    if matches!(loader, ModLoader::Vanilla) {
        return Ok(vec![]);
    }
    let manifest = fetch_loader_manifest(resource_dir, loader).await?;
    // Meta catch-all: id="${modrinth.gameVersion}".
    let entry = manifest
        .game_versions
        .into_iter()
        .find(|g| g.id.replace(DUMMY_REPLACE_STRING, game_version) == game_version)
        .ok_or_else(|| anyhow!("loader does not support game version {game_version}"))?;
    Ok(entry
        .loaders
        .into_iter()
        .map(|l| LoaderVersionDto {
            id: l.id,
            url: l.url,
            stable: l.stable,
        })
        .collect())
}

#[derive(Clone, Debug)]
pub struct LoaderVersionDto {
    pub id: String,
    pub url: String,
    pub stable: bool,
}

pub async fn resolve_version_info(
    resource_dir: &str,
    game_version: &str,
    loader: &ModLoader,
    loader_version: Option<&str>,
) -> Result<(VersionInfo, String)> {
    let mc_manifest = fetch_minecraft_manifest(resource_dir).await?;
    let version = mc_manifest
        .versions
        .iter()
        .find(|v| v.id == game_version)
        .ok_or_else(|| anyhow!("unknown Minecraft version: {game_version}"))?
        .clone();

    let client = http_client()?;
    let version_json = client
        .get(&version.url)
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    let mut info: VersionInfo =
        serde_json::from_str(&version_json).with_context(|| "parse minecraft version json")?;

    let version_jar_id = if matches!(loader, ModLoader::Vanilla) {
        game_version.to_string()
    } else {
        let lv = resolve_loader_version(resource_dir, loader, game_version, loader_version).await?;
        let partial_text = client
            .get(&lv.url)
            .send()
            .await?
            .error_for_status()?
            .text()
            .await?;
        let partial: PartialVersionInfo =
            serde_json::from_str(&partial_text).with_context(|| "parse loader partial version")?;
        info = merge_partial_version(partial, info);
        format!("{game_version}-{}", lv.id)
    };

    let dir = dirs::versions(resource_dir).join(&version_jar_id);
    tokio::fs::create_dir_all(&dir).await?;
    let path = dir.join(format!("{version_jar_id}.json"));
    tokio::fs::write(&path, serde_json::to_string_pretty(&info)?).await?;
    if let Ok(mut cache) = VERSION_INFO_CACHE.write() {
        cache.insert(path, info.clone());
    }

    Ok((info, version_jar_id))
}

/// Resolve pack `dependencies.fabric-loader` / forge / etc. to meta loader id.
pub async fn resolve_loader_meta_id(
    resource_dir: &str,
    game_version: &str,
    loader: &ModLoader,
    loader_version: Option<&str>,
) -> Result<Option<String>> {
    if matches!(loader, ModLoader::Vanilla) {
        return Ok(None);
    }
    let lv = resolve_loader_version(resource_dir, loader, game_version, loader_version).await?;
    Ok(Some(lv.id))
}

/// Keep pack-declared loader version when meta lookup fails.
pub async fn resolve_loader_meta_id_or_fallback(
    resource_dir: &str,
    game_version: &str,
    loader: &ModLoader,
    loader_version: Option<String>,
) -> Option<String> {
    if matches!(loader, ModLoader::Vanilla) {
        return None;
    }
    resolve_loader_meta_id(
        resource_dir,
        game_version,
        loader,
        loader_version.as_deref(),
    )
    .await
    .ok()
    .flatten()
    .or(loader_version)
}

async fn resolve_loader_version(
    resource_dir: &str,
    loader: &ModLoader,
    game_version: &str,
    loader_version: Option<&str>,
) -> Result<LoaderVersion> {
    let versions = list_loader_versions(resource_dir, loader, game_version).await?;
    if versions.is_empty() {
        anyhow::bail!("no loader versions for {game_version}");
    }
    let chosen = if let Some(want) = loader_version {
        if want == "latest" {
            versions.first().cloned()
        } else if want == "stable" {
            versions
                .iter()
                .find(|v| v.stable)
                .cloned()
                .or_else(|| versions.first().cloned())
        } else {
            // Exact match first (Fabric/Quilt IDs are plain e.g. 0.16.14).
            versions
                .iter()
                .find(|v| v.id == want)
                .cloned()
                // Forge packs often ship "1.20.1-47.2.0" while meta id is "47.2.0".
                .or_else(|| {
                    let stripped = want
                        .strip_prefix(&format!("{game_version}-"))
                        .unwrap_or_else(|| want.rsplit_once('-').map(|(_, r)| r).unwrap_or(want));
                    versions.iter().find(|v| v.id == stripped).cloned()
                })
                // Last resort: stable / first.
                .or_else(|| {
                    versions
                        .iter()
                        .find(|v| v.stable)
                        .cloned()
                        .or_else(|| versions.first().cloned())
                })
        }
    } else {
        versions
            .iter()
            .find(|v| v.stable)
            .cloned()
            .or_else(|| versions.first().cloned())
    }
    .ok_or_else(|| anyhow!("loader version not found"))?;

    Ok(LoaderVersion {
        id: chosen.id,
        url: chosen.url,
        stable: chosen.stable,
    })
}

pub fn version_index_in_manifest(manifest: &VersionManifest, game_version: &str) -> Result<usize> {
    manifest
        .versions
        .iter()
        .position(|v| v.id == game_version)
        .ok_or_else(|| anyhow!("unknown Minecraft version: {game_version}"))
}

pub async fn load_cached_version_info(
    resource_dir: &str,
    version_jar_id: &str,
) -> Result<VersionInfo> {
    let path = dirs::versions(resource_dir)
        .join(version_jar_id)
        .join(format!("{version_jar_id}.json"));
    if let Some(info) = VERSION_INFO_CACHE
        .read()
        .ok()
        .and_then(|cache| cache.get(&path).cloned())
    {
        return Ok(info);
    }
    let text = tokio::fs::read_to_string(&path)
        .await
        .with_context(|| format!("missing version json at {}", path.display()))?;
    let info: VersionInfo = serde_json::from_str(&text)?;
    if let Ok(mut cache) = VERSION_INFO_CACHE.write() {
        cache.insert(path, info.clone());
    }
    Ok(info)
}

pub fn version_jar_id_for_instance(
    game_version: &str,
    loader: &ModLoader,
    loader_version: Option<&str>,
) -> String {
    if matches!(loader, ModLoader::Vanilla) {
        game_version.to_string()
    } else {
        format!("{game_version}-{}", loader_version.unwrap_or("unknown"))
    }
}
