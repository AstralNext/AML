//! `.mrpack` (Modrinth pack format) installation: index parsing, concurrent
//! file download with mirrors, overrides extraction.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::io::{Cursor, Read};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use futures::stream::{FuturesUnordered, StreamExt};
use tokio::sync::Semaphore;
use zip::ZipArchive;

use super::files::sync_instance_content_metadata;
use super::install::download_with_mirrors;
use crate::launcher::dirs;
use crate::launcher::download::{self, ProgressFn, PACK_DOWNLOAD_CONCURRENCY};
use crate::launcher::icons;
use crate::launcher::install;
use crate::launcher::manifest;
use crate::launcher::pack;
use crate::launcher::progress;
use crate::state::db;
use crate::state::models::ModLoader;
use crate::state::{resource_dir, try_state};

#[derive(Deserialize)]
pub(super) struct MrpackIndex {
    files: Vec<MrpackFile>,
    pub(super) dependencies: MrpackDependencies,
    pub(super) name: Option<String>,
}

#[derive(Deserialize)]
struct MrpackFile {
    path: String,
    downloads: Vec<String>,
    #[serde(default)]
    hashes: Option<MrpackHashes>,
    env: Option<MrpackEnv>,
}

#[derive(Deserialize)]
struct MrpackHashes {
    sha1: Option<String>,
    #[serde(default)]
    sha512: Option<String>,
}

#[derive(Deserialize)]
struct MrpackEnv {
    client: Option<String>,
}

#[derive(Deserialize)]
pub(super) struct MrpackDependencies {
    pub(super) minecraft: String,
    #[serde(rename = "fabric-loader")]
    pub(super) fabric_loader: Option<String>,
    #[serde(rename = "quilt-loader")]
    pub(super) quilt_loader: Option<String>,
    pub(super) forge: Option<String>,
    #[serde(rename = "neoforge", alias = "neo-forge")]
    pub(super) neoforge: Option<String>,
}

pub async fn install_mrpack(
    instance_id: &str,
    mrpack_path: &str,
    java_path: Option<String>,
    on_progress: Option<ProgressFn>,
) -> Result<()> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let mut instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::ensure_instance_dir(&resource, &instance.path).await?;

    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    report(0.05, "Reading mrpack…".into());
    let data = tokio::fs::read(mrpack_path).await?;
    let mut archive = ZipArchive::new(Cursor::new(data))?;
    let index: MrpackIndex = {
        let mut file = archive
            .by_name("modrinth.index.json")
            .context("mrpack missing modrinth.index.json")?;
        let mut text = String::new();
        file.read_to_string(&mut text)?;
        serde_json::from_str(&text)?
    };

    let loader = if let Some(v) = &index.dependencies.fabric_loader {
        (ModLoader::Fabric, Some(v.clone()))
    } else if let Some(v) = &index.dependencies.quilt_loader {
        (ModLoader::Quilt, Some(v.clone()))
    } else if let Some(v) = &index.dependencies.forge {
        (ModLoader::Forge, Some(v.clone()))
    } else if let Some(v) = &index.dependencies.neoforge {
        (ModLoader::NeoForge, Some(v.clone()))
    } else {
        (ModLoader::Vanilla, None)
    };

    let game_version = index.dependencies.minecraft.clone();
    let resolved_loader_version = manifest::resolve_loader_meta_id_or_fallback(
        &resource,
        &game_version,
        &loader.0,
        loader.1.clone(),
    )
    .await;

    report(
        0.08,
        format!(
            "Pack profile: Minecraft {game_version}, {} {}",
            loader.0.as_str(),
            resolved_loader_version.as_deref().unwrap_or("(vanilla)")
        ),
    );

    sqlx::query(
        "UPDATE instances SET game_version = ?, loader = ?, loader_version = ? WHERE id = ?",
    )
    .bind(&game_version)
    .bind(loader.0.as_str())
    .bind(&resolved_loader_version)
    .bind(instance_id)
    .execute(&state.pool)
    .await?;
    instance = db::get_instance(&state.pool, instance_id).await?;
    let pack_name = index.name.clone();

    let client = manifest::http_client()?;
    // Skip files unsupported on the client.
    let files: Vec<_> = index
        .files
        .into_iter()
        .filter(|f| {
            f.env
                .as_ref()
                .and_then(|e| e.client.as_deref())
                .map(|c| !c.eq_ignore_ascii_case("unsupported"))
                .unwrap_or(true)
        })
        .collect();
    let file_count = files.len() as u64;
    let sem = Arc::new(Semaphore::new(PACK_DOWNLOAD_CONCURRENCY));
    let skipped = Arc::new(AtomicUsize::new(0));
    let mut futs = FuturesUnordered::new();
    let batch = on_progress.clone().map(|cb| {
        progress::BatchReporter::new(
            cb,
            "Downloading pack files",
            0.12,
            0.70,
            file_count.max(1),
        )
    });

    let pool = state.pool.clone();
    let instance_id_owned = instance_id.to_string();

    for file in files {
        let client = client.clone();
        let sem = sem.clone();
        let skipped = skipped.clone();
        let batch = batch.clone();
        let instance_dir = instance_dir.clone();
        let pool = pool.clone();
        let instance_id = instance_id_owned.clone();
        futs.push(async move {
            let _permit = sem.acquire().await.ok();
            let dest = instance_dir.join(&file.path);
            let expected = file.hashes.as_ref().and_then(|h| h.sha1.clone());
            let file_name = Path::new(&file.path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| file.path.clone());

            if download::file_already_ok(&dest, expected.as_deref()).await {
                if let Some(b) = &batch {
                    b.skip_file();
                }
                return Ok::<(), anyhow::Error>(());
            }

            let on_bytes = batch.as_ref().map(|b| b.file_bytes_cb(&file_name));
            let bytes = match download_with_mirrors(&client, &file.downloads, on_bytes).await {
                Ok(b) => b,
                Err(e) => {
                    eprintln!("[AML] Skipping missing mrpack file {}: {e:#}", file.path);
                    let entry = mrpack_file_content_entry(
                        &instance_id,
                        &file,
                        true,
                        expected,
                        None,
                    );
                    let _ = db::upsert_content_entry(&pool, &entry).await;
                    skipped.fetch_add(1, Ordering::Relaxed);
                    if let Some(b) = &batch {
                        b.finish_file();
                    }
                    return Ok(());
                }
            };

            if let Some(expected_hash) = expected.as_deref() {
                let actual = download::sha1_hex(&bytes);
                if !actual.eq_ignore_ascii_case(expected_hash) {
                    eprintln!(
                        "[AML] Skipping hash-mismatch mrpack file {}: expected {expected_hash}, got {actual}",
                        file.path
                    );
                    let entry = mrpack_file_content_entry(
                        &instance_id,
                        &file,
                        true,
                        expected,
                        None,
                    );
                    let _ = db::upsert_content_entry(&pool, &entry).await;
                    skipped.fetch_add(1, Ordering::Relaxed);
                    if let Some(b) = &batch {
                        b.finish_file();
                    }
                    return Ok(());
                }
            }

            if let Some(parent) = dest.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }
            tokio::fs::write(&dest, &bytes).await?;
            if let Some(b) = &batch {
                b.finish_file();
            }
            Ok(())
        });
    }

    while let Some(res) = futs.next().await {
        res?;
    }

    let skipped_count = skipped.load(Ordering::Relaxed) as u32;
    if skipped_count > 0 {
        report(
            0.70,
            format!("已跳过 {skipped_count} 个丢失/校验失败的文件"),
        );
        report(0.71, format!("__SKIPPED_FILES__:{skipped_count}"));
    }

    report(0.72, "Extracting overrides…".into());
    extract_overrides(&mut archive, &instance_dir, "overrides/")?;
    extract_overrides(&mut archive, &instance_dir, "client-overrides/")?;
    if !instance_dir.join("icon.png").exists() {
        let _ = pack::try_extract_pack_icon_from_archive(&mut archive, &instance_dir)?;
    }

    // Pack may ship icon.png in overrides; prefer over project icon when present.
    let pack_icon = instance_dir.join("icon.png");
    if pack_icon.exists() {
        if let Ok(Some(cached)) = icons::resolve_icon_from_path(&resource, &pack_icon).await {
            let _ = icons::set_instance_icon(&state.pool, instance_id, Some(cached)).await;
        }
    }

    // Install Minecraft + mod loader after pack files and overrides.
    report(0.78, "Installing Minecraft + loader…".into());
    install::install_instance(
        instance_id,
        java_path,
        false,
        progress::nest_progress(
            on_progress.clone(),
            0.78,
            0.95,
            "Installing Minecraft + loader",
        ),
    )
    .await?;

    report(0.95, "Indexing installed content…".into());
    let _ = sync_instance_content_metadata(instance_id, false).await;

    // Local .mrpack installs without an existing Modrinth link become "file" packs.
    if instance.modpack_source.is_none() {
        let title = pack_name.unwrap_or_else(|| instance.name.clone());
        let _ = db::set_instance_modpack_link(
            &state.pool,
            instance_id,
            None,
            None,
            None,
            Some("file"),
            Some(&title),
        )
        .await;
    }

    report(1.0, "Modpack installed".into());
    Ok(())
}

fn project_type_from_rel(rel: &str) -> String {
    let rel = rel.replace('\\', "/").to_lowercase();
    if rel.starts_with("resourcepacks/") {
        "resourcepack".into()
    } else if rel.starts_with("shaderpacks/") {
        "shader".into()
    } else if rel.starts_with("datapacks/") {
        "datapack".into()
    } else {
        "mod".into()
    }
}

fn mrpack_file_content_entry(
    instance_id: &str,
    file: &MrpackFile,
    pending: bool,
    sha1: Option<String>,
    size_bytes: Option<i64>,
) -> db::ContentEntry {
    let rel = file.path.replace('\\', "/");
    let file_name = Path::new(&rel)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| rel.clone());
    db::ContentEntry {
        id: format!("content:{}", uuid::Uuid::new_v4()),
        instance_id: instance_id.to_string(),
        relative_path: rel,
        file_name: file_name.clone(),
        project_type: project_type_from_rel(&file.path),
        project_id: None,
        version_id: None,
        version_number: Some(file_name.clone()),
        version_name: Some(file_name),
        project_title: None,
        project_icon_url: None,
        author: None,
        author_avatar_url: None,
        author_id: None,
        author_type: None,
        update_version_id: None,
        enabled: true,
        sha1,
        size_bytes,
        added_at: chrono::Utc::now().to_rfc3339(),
        pending,
        download_url: file.downloads.first().cloned(),
    }
}

/// Extract `overrides/` (or `client-overrides/`) entries from a pack archive
/// into the instance directory. Shared with the CurseForge / MMC pack importers.
pub(crate) fn extract_overrides<R: std::io::Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    dest_root: &Path,
    prefix: &str,
) -> Result<()> {
    for i in 0..archive.len() {
        let mut file = archive.by_index(i)?;
        let name = file.name().to_string();
        if !name.starts_with(prefix) || name.ends_with('/') {
            continue;
        }
        let rel = &name[prefix.len()..];
        // Zip-slip guard.
        let out = dest_root.join(rel);
        let canon_root = dest_root.canonicalize().unwrap_or_else(|_| dest_root.to_path_buf());
        if let Ok(canon_out) = out.canonicalize() {
            if !canon_out.starts_with(&canon_root) {
                continue;
            }
        } else if rel.contains("..") {
            continue;
        }
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut outfile = std::fs::File::create(&out)?;
        std::io::copy(&mut file, &mut outfile)?;
    }
    Ok(())
}
