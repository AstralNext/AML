use anyhow::{Context, Result};
use futures::stream::{FuturesUnordered, StreamExt};
use serde::Deserialize;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::{Mutex, Semaphore};
use zip::ZipArchive;

use crate::launcher::dirs;
use crate::launcher::download::{ProgressFn, PACK_DOWNLOAD_CONCURRENCY};
use crate::launcher::install;
use crate::launcher::progress;
use crate::state::db;
use crate::state::models::{CreateInstanceRequest, InstallStage, Instance, ModLoader};
use crate::state::{resource_dir, try_state};

use super::curseforge::{
    content_relative_path, download_cf_file, extract_named_overrides, parse_manifest_json,
    read_cf_meta_from_zip, resolve_file_downloads, CfFileRef, CfPackMeta,
};
use super::detect::{detect_pack_bytes, read_zip_entry, PackKind};
use super::export_common::{PackContentCategory, PackContentFile};
use super::mmc::{extract_mmc_minecraft, read_mmc_meta_from_dir, read_mmc_meta_from_zip};

#[derive(Debug, Clone)]
pub struct PackImportPreview {
    pub kind: String,
    pub kind_label: String,
    pub name: String,
    pub version: Option<String>,
    pub game_version: Option<String>,
    pub loader: Option<String>,
    pub categories: Vec<PackContentCategory>,
    /// True when the zip contains an `icon.png` (or overrides equivalent).
    pub has_cover: bool,
    /// Raw PNG bytes for preview thumbnail (same file as [has_cover]).
    pub cover_png: Option<Vec<u8>>,
}

pub async fn preview_pack_file(path: &Path) -> Result<PackImportPreview> {
    let data = tokio::fs::read(path).await?;
    let kind = detect_pack_bytes(&data)?;
    let (name, version, game_version, loader) = match kind {
        PackKind::Mrpack => {
            let mut archive = ZipArchive::new(Cursor::new(&data))?;
            let text = read_zip_entry(&mut archive, "modrinth.index.json")?;
            let v: serde_json::Value = serde_json::from_str(&text)?;
            let name = v
                .get("name")
                .and_then(|x| x.as_str())
                .unwrap_or("Modrinth Pack")
                .to_string();
            let version = v
                .get("versionId")
                .or_else(|| v.get("version_id"))
                .and_then(|x| x.as_str())
                .map(|s| s.to_string());
            let deps = v.get("dependencies");
            let game = deps
                .and_then(|d| d.get("minecraft"))
                .and_then(|x| x.as_str())
                .map(|s| s.to_string());
            let loader = deps.and_then(|d| {
                ["fabric-loader", "quilt-loader", "forge", "neoforge"]
                    .iter()
                    .find_map(|k| d.get(*k).and_then(|x| x.as_str()).map(|_s| (*k).to_string()))
            });
            (name, version, game, loader)
        }
        PackKind::CurseForge => {
            let (meta, _) = read_cf_meta_from_zip(&data)?;
            (
                meta.name,
                meta.version,
                Some(meta.game_version),
                Some(meta.loader.as_str().to_string()),
            )
        }
        PackKind::Mcbbs => {
            let (meta, raw) = read_mcbbs_meta(&data)?;
            let version = serde_json::from_str::<serde_json::Value>(&raw)
                .ok()
                .and_then(|v| v.get("version").and_then(|x| x.as_str()).map(|s| s.to_string()))
                .or_else(|| {
                    // Prefer typed field when present in packmeta JSON.
                    serde_json::from_str::<McbbsPackmeta>(&raw)
                        .ok()
                        .and_then(|p| p.version)
                });
            (
                meta.name,
                version,
                Some(meta.game_version),
                Some(meta.loader.as_str().to_string()),
            )
        }
        PackKind::MultiMc => {
            let meta = read_mmc_meta_from_zip(&data)?;
            (
                meta.name,
                None,
                Some(meta.game_version),
                Some(meta.loader.as_str().to_string()),
            )
        }
    };
    let categories = summarize_pack_archive(&data, kind)?;
    let cover = super::icon::find_pack_icon_bytes(&data);
    let has_cover = cover.is_some();
    let cover_png = cover.map(|(_, bytes)| bytes);
    Ok(PackImportPreview {
        kind: kind.as_str().to_string(),
        kind_label: kind.display_name().to_string(),
        name,
        version,
        game_version,
        loader,
        categories,
        has_cover,
        cover_png,
    })
}

fn summarize_pack_archive(data: &[u8], kind: PackKind) -> Result<Vec<PackContentCategory>> {
    use std::collections::BTreeMap;
    let mut archive = ZipArchive::new(Cursor::new(data))?;
    let mut map: BTreeMap<&'static str, PackContentCategory> = BTreeMap::new();

    let bump = |map: &mut BTreeMap<&'static str, PackContentCategory>,
                id: &'static str,
                label: &'static str,
                path: String,
                size: u64| {
        let name = path
            .rsplit('/')
            .next()
            .unwrap_or(path.as_str())
            .to_string();
        let entry = map.entry(id).or_insert_with(|| PackContentCategory {
            id: id.into(),
            label: label.into(),
            file_count: 0,
            total_bytes: 0,
            files: Vec::new(),
        });
        // Deduplicate by path (mrpack index + overrides).
        if entry.files.iter().any(|f| f.path == path) {
            return;
        }
        entry.file_count += 1;
        entry.total_bytes += size;
        entry.files.push(PackContentFile {
            path,
            name,
            size_bytes: size,
            icon_url: None,
            title: None,
        });
    };

    // Prefer mrpack index file list for remote mods.
    if kind == PackKind::Mrpack {
        if let Ok(text) = read_zip_entry(&mut archive, "modrinth.index.json") {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                if let Some(files) = v.get("files").and_then(|x| x.as_array()) {
                    for f in files {
                        let path = f
                            .get("path")
                            .and_then(|x| x.as_str())
                            .unwrap_or("")
                            .replace('\\', "/");
                        let size = f.get("fileSize").and_then(|x| x.as_u64()).unwrap_or(0);
                        let top = path.split('/').next().unwrap_or("");
                        if let Some((id, label)) = category_id_for_top(top) {
                            bump(&mut map, id, label, path, size);
                        }
                    }
                }
            }
        }
    }

    for i in 0..archive.len() {
        let file = archive.by_index(i)?;
        if file.is_dir() {
            continue;
        }
        let name = file.name().replace('\\', "/");
        // mrpack remote files are already counted from modrinth.index.json.
        if matches!(kind, PackKind::Mrpack)
            && !name.contains("overrides/")
            && name != "overrides"
        {
            continue;
        }
        let size = file.size();
        let content_path = normalize_pack_content_path(&name, kind);
        let Some(content_path) = content_path else {
            continue;
        };
        let top = content_path.split('/').next().unwrap_or("");
        let Some((id, label)) = category_id_for_top(top) else {
            if content_path == "options.txt" {
                bump(&mut map, "options", "游戏选项", content_path, size);
            }
            continue;
        };
        bump(&mut map, id, label, content_path, size);
    }

    let order = [
        "mods",
        "resourcepacks",
        "shaderpacks",
        "datapacks",
        "config",
        "options",
        "saves",
    ];
    let mut out = Vec::new();
    for id in order {
        if let Some(mut cat) = map.remove(id) {
            cat.files
                .sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
            out.push(cat);
        }
    }
    for mut cat in map.into_values() {
        cat.files
            .sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        out.push(cat);
    }
    Ok(out)
}

fn category_id_for_top(top: &str) -> Option<(&'static str, &'static str)> {
    match top {
        "mods" => Some(("mods", "模组")),
        "resourcepacks" => Some(("resourcepacks", "资源包")),
        "shaderpacks" => Some(("shaderpacks", "光影包")),
        "datapacks" => Some(("datapacks", "数据包")),
        "config" | "configs" | "defaultconfigs" | "kubejs" | "scripts" | "patchouli_books" => {
            Some(("config", "配置与脚本"))
        }
        "options.txt" => Some(("options", "游戏选项")),
        "saves" => Some(("saves", "存档")),
        _ => None,
    }
}

fn normalize_pack_content_path(zip_name: &str, kind: PackKind) -> Option<String> {
    let name = zip_name.trim_start_matches('/');
    match kind {
        PackKind::Mrpack | PackKind::Mcbbs | PackKind::CurseForge => {
            if let Some(rest) = name.strip_prefix("overrides/") {
                return Some(rest.to_string());
            }
            if let Some(rest) = name.strip_prefix("override/") {
                return Some(rest.to_string());
            }
            // CurseForge sometimes uses minecraft/
            if let Some(rest) = name.strip_prefix("minecraft/") {
                return Some(rest.to_string());
            }
            None
        }
        PackKind::MultiMc => {
            // {instance}/minecraft/...
            let parts: Vec<&str> = name.split('/').collect();
            if parts.len() >= 3 && parts[1] == "minecraft" {
                return Some(parts[2..].join("/"));
            }
            None
        }
    }
}

/// Create a new instance from a local pack archive (.mrpack / .zip).
pub async fn create_instance_from_pack_file_resumable(
    pack_path: &str,
    name: Option<String>,
    java_path: Option<String>,
    resume_instance_id: Option<&str>,
    on_progress: Option<ProgressFn>,
) -> Result<Instance> {
    let path = PathBuf::from(pack_path);
    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    report(0.02, "Reading pack…".into());
    let data = tokio::fs::read(&path).await.context("读取整合包失败")?;
    let kind = detect_pack_bytes(&data)?;
    report(0.05, format!("Detected {} pack", kind.display_name()));

    match kind {
        PackKind::Mrpack => {
            let state = try_state()?;
            let created = if let Some(id) = resume_instance_id {
                report(0.08, format!("Resuming instance {id}…"));
                report(0.08, format!("__INSTANCE_CREATED__:{id}"));
                db::set_install_stage(&state.pool, id, InstallStage::Installing).await?;
                db::get_instance(&state.pool, id).await?
            } else {
                let mut archive = ZipArchive::new(Cursor::new(&data))?;
                let text = read_zip_entry(&mut archive, "modrinth.index.json")?;
                let v: serde_json::Value = serde_json::from_str(&text)?;
                let pack_name = name.or_else(|| {
                    v.get("name")
                        .and_then(|x| x.as_str())
                        .map(|s| s.to_string())
                });
                let deps = v.get("dependencies").cloned().unwrap_or_default();
                let game_version = deps
                    .get("minecraft")
                    .and_then(|x| x.as_str())
                    .unwrap_or("1.20.1")
                    .to_string();
                let (loader, loader_version) = if let Some(v) = deps.get("fabric-loader") {
                    (ModLoader::Fabric, v.as_str().map(|s| s.to_string()))
                } else if let Some(v) = deps.get("quilt-loader") {
                    (ModLoader::Quilt, v.as_str().map(|s| s.to_string()))
                } else if let Some(v) = deps.get("forge") {
                    (ModLoader::Forge, v.as_str().map(|s| s.to_string()))
                } else if let Some(v) = deps.get("neoforge").or_else(|| deps.get("neo-forge")) {
                    (ModLoader::NeoForge, v.as_str().map(|s| s.to_string()))
                } else {
                    (ModLoader::Vanilla, None)
                };

                let created = db::create_instance(
                    &state.pool,
                    CreateInstanceRequest {
                        name: pack_name.unwrap_or_else(|| {
                            path.file_stem()
                                .map(|s| s.to_string_lossy().into_owned())
                                .unwrap_or_else(|| "Imported Pack".into())
                        }),
                        game_version,
                        loader,
                        loader_version,
                        icon: None,
                    },
                )
                .await?;
                report(0.08, format!("__INSTANCE_CREATED__:{}", created.id));
                created
            };
            let install_result = super::super::content::install_mrpack(
                &created.id,
                pack_path,
                java_path,
                on_progress,
            )
            .await;
            if let Err(e) = install_result {
                let _ = db::set_install_stage(&state.pool, &created.id, InstallStage::Failed).await;
                return Err(e);
            }
            db::get_instance(&state.pool, &created.id).await
        }
        PackKind::CurseForge => {
            install_curse_like(
                &data,
                name,
                java_path,
                on_progress,
                "curseforge",
                resume_instance_id,
            )
            .await
        }
        PackKind::Mcbbs => {
            install_mcbbs(&data, name, java_path, on_progress, resume_instance_id).await
        }
        PackKind::MultiMc => {
            install_multimc_zip(&data, name, java_path, on_progress, resume_instance_id).await
        }
    }
}

async fn install_curse_like(
    data: &[u8],
    name: Option<String>,
    java_path: Option<String>,
    on_progress: Option<ProgressFn>,
    source: &str,
    resume_instance_id: Option<&str>,
) -> Result<Instance> {
    let (meta, zip_prefix) = read_cf_meta_from_zip(data)?;
    install_from_cf_meta(
        data,
        meta,
        zip_prefix,
        name,
        java_path,
        on_progress,
        source,
        resume_instance_id,
    )
    .await
}

async fn install_from_cf_meta(
    data: &[u8],
    meta: CfPackMeta,
    zip_prefix: String,
    name: Option<String>,
    java_path: Option<String>,
    on_progress: Option<ProgressFn>,
    source: &str,
    resume_instance_id: Option<&str>,
) -> Result<Instance> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    let instance_name = name.unwrap_or_else(|| meta.name.clone());
    let created = if let Some(id) = resume_instance_id {
        report(0.08, format!("Resuming instance {id}…"));
        report(0.10, format!("__INSTANCE_CREATED__:{id}"));
        db::set_install_stage(&state.pool, id, InstallStage::Installing).await?;
        db::get_instance(&state.pool, id).await?
    } else {
        report(0.08, format!("Creating instance {instance_name}…"));
        let created = db::create_instance(
            &state.pool,
            CreateInstanceRequest {
                name: instance_name.clone(),
                game_version: meta.game_version.clone(),
                loader: meta.loader,
                loader_version: meta.loader_version.clone(),
                icon: None,
            },
        )
        .await?;
        report(0.10, format!("__INSTANCE_CREATED__:{}", created.id));
        db::set_install_stage(&state.pool, &created.id, InstallStage::Installing).await?;
        created
    };

    let instance_dir = dirs::ensure_instance_dir(&resource, &created.path).await?;

    let install_body = async {
        // Split direct-URL entries from CurseForge id entries.
        let (direct, api_files): (Vec<_>, Vec<_>) = meta
            .files
            .iter()
            .cloned()
            .partition(|f| f.project_id == 0 && f.url.is_some());

        report(0.12, "Resolving CurseForge files…".into());
        let mut resolved = resolve_file_downloads(&api_files).await?;
        for f in direct {
            let url = f.url.clone().unwrap_or_default();
            let name = f
                .file_name
                .clone()
                .unwrap_or_else(|| url.rsplit('/').next().unwrap_or("mod.jar").to_string());
            resolved.push((f, name, url));
        }

        let total = resolved.len() as u64;
        let sem = Arc::new(Semaphore::new(PACK_DOWNLOAD_CONCURRENCY));
        let skipped = Arc::new(Mutex::new(Vec::<String>::new()));
        let mut futs = FuturesUnordered::new();
        let batch = on_progress.clone().map(|cb| {
            progress::BatchReporter::new(cb, "Downloading pack files", 0.12, 0.66, total.max(1))
        });
        let pool = state.pool.clone();
        let instance_id = created.id.clone();
        let instance_dir_dl = instance_dir.clone();

        for (file, file_name, url) in resolved {
            let sem = sem.clone();
            let skipped = skipped.clone();
            let batch = batch.clone();
            let pool = pool.clone();
            let instance_id = instance_id.clone();
            let instance_dir_dl = instance_dir_dl.clone();
            futs.push(async move {
                let _permit = sem.acquire().await.ok();
                let rel = content_relative_path(&file_name);
                let dest = instance_dir_dl.join(&rel);

                if crate::launcher::download::file_already_ok(&dest, None).await {
                    if let Some(b) = &batch {
                        b.skip_file();
                    }
                    return Ok::<(), anyhow::Error>(());
                }

                let on_bytes = batch.as_ref().map(|b| b.file_bytes_cb(&file_name));
                match download_cf_file(&url, on_bytes).await {
                    Ok(bytes) => {
                        if let Some(parent) = dest.parent() {
                            tokio::fs::create_dir_all(parent).await?;
                        }
                        tokio::fs::write(&dest, &bytes).await?;
                        let sha1 = crate::launcher::download::sha1_hex(&bytes);
                        let entry = pack_file_content_entry(
                            instance_id,
                            &rel,
                            &file_name,
                            &file,
                            Some(url),
                            Some(sha1),
                            Some(bytes.len() as i64),
                            false,
                        );
                        let _ = db::upsert_content_entry(&pool, &entry).await;
                        if let Some(b) = &batch {
                            b.finish_file();
                        }
                    }
                    Err(e) => {
                        let detail = format!("{e:#}");
                        eprintln!("[AML] Skipping missing pack file {file_name}: {detail}");
                        let entry = pack_file_content_entry(
                            instance_id,
                            &rel,
                            &file_name,
                            &file,
                            Some(url),
                            None,
                            None,
                            true,
                        );
                        let _ = db::upsert_content_entry(&pool, &entry).await;
                        skipped.lock().await.push(file_name);
                        if let Some(b) = &batch {
                            b.finish_file();
                        }
                    }
                }
                Ok(())
            });
        }

        while let Some(res) = futs.next().await {
            res?;
        }

        let skipped = skipped.lock().await.clone();
        if !skipped.is_empty() {
            let preview = if skipped.len() <= 3 {
                skipped.join("、")
            } else {
                format!(
                    "{} 等 {} 个",
                    skipped.iter().take(3).cloned().collect::<Vec<_>>().join("、"),
                    skipped.len()
                )
            };
            report(
                0.66,
                format!("已跳过 {} 个丢失文件：{preview}", skipped.len()),
            );
            // Flutter may surface this in the success toast.
            report(0.67, format!("__SKIPPED_FILES__:{}", skipped.len()));
        }

        report(0.68, "Extracting overrides…".into());
        extract_named_overrides(data, &instance_dir, &meta.overrides, &zip_prefix)?;

        // Prefer icon shipped in the zip (overrides or root); fall back to already-extracted.
        let _ = super::icon::try_extract_pack_icon_to(data, &instance_dir);

        if instance_dir.join("icon.png").exists() {
            if let Ok(Some(cached)) = crate::launcher::icons::resolve_icon_from_path(
                &resource,
                &instance_dir.join("icon.png"),
            )
            .await
            {
                let _ = crate::launcher::icons::set_instance_icon(
                    &state.pool,
                    &created.id,
                    Some(cached),
                )
                .await;
            }
        }

        report(0.78, "Installing Minecraft + loader…".into());
        install::install_instance(
            &created.id,
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
        let _ = crate::launcher::content::sync_instance_content_metadata(&created.id, false).await;

        let _ = db::set_instance_modpack_link(
            &state.pool,
            &created.id,
            None,
            None,
            meta.version.as_deref(),
            Some(source),
            Some(&instance_name),
        )
        .await;

        report(1.0, "Modpack installed".into());
        Ok::<(), anyhow::Error>(())
    }
    .await;

    if let Err(e) = install_body {
        let _ = db::set_install_stage(&state.pool, &created.id, InstallStage::Failed).await;
        return Err(e);
    }

    db::get_instance(&state.pool, &created.id).await
}

#[derive(Debug, Clone)]
struct McbbsMeta {
    name: String,
    game_version: String,
    loader: ModLoader,
    loader_version: Option<String>,
    files: Vec<CfFileRef>,
    overrides: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct McbbsPackmeta {
    name: Option<String>,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    files: Vec<McbbsFile>,
    #[serde(default)]
    addons: Vec<McbbsAddon>,
    #[serde(default)]
    overrides: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct McbbsFile {
    #[serde(default, rename = "type")]
    file_type: Option<String>,
    #[serde(default, rename = "projectID")]
    project_id: Option<u64>,
    #[serde(default, rename = "fileID")]
    file_id: Option<u64>,
    #[serde(default)]
    file_name: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    force: Option<bool>,
}

#[derive(Deserialize)]
struct McbbsAddon {
    id: String,
    version: String,
}

fn read_mcbbs_meta(data: &[u8]) -> Result<(McbbsMeta, String)> {
    use super::detect::zip_entry_prefix;
    let mut archive = ZipArchive::new(Cursor::new(data))?;
    let zip_prefix = zip_entry_prefix(&mut archive, "mcbbs.packmeta");
    let text = read_zip_entry(&mut archive, "mcbbs.packmeta")?;
    let pack: McbbsPackmeta =
        serde_json::from_str(&text).context("解析 mcbbs.packmeta 失败")?;

    let mut game_version = String::new();
    let mut loader = ModLoader::Vanilla;
    let mut loader_version = None;
    for addon in &pack.addons {
        let id = addon.id.to_lowercase();
        if id == "game" || id == "minecraft" {
            game_version = addon.version.clone();
        } else if id.contains("fabric") {
            loader = ModLoader::Fabric;
            loader_version = Some(addon.version.clone());
        } else if id.contains("quilt") {
            loader = ModLoader::Quilt;
            loader_version = Some(addon.version.clone());
        } else if id.contains("neoforge") {
            loader = ModLoader::NeoForge;
            loader_version = Some(addon.version.clone());
        } else if id.contains("forge") {
            loader = ModLoader::Forge;
            loader_version = Some(addon.version.clone());
        }
    }

    if game_version.is_empty() {
        if let Ok(manifest_text) = read_zip_entry(&mut archive, "manifest.json") {
            if let Ok(cf) = parse_manifest_json(&manifest_text) {
                game_version = cf.game_version;
                loader = cf.loader;
                loader_version = cf.loader_version;
            }
        }
    }
    if game_version.is_empty() {
        anyhow::bail!("mcbbs.packmeta 缺少游戏版本");
    }

    let mut files = Vec::new();
    for f in pack.files {
        let is_curse = f
            .file_type
            .as_deref()
            .map(|t| t.eq_ignore_ascii_case("curse") || t.eq_ignore_ascii_case("addon"))
            .unwrap_or(f.project_id.is_some() && f.file_id.is_some());
        if is_curse {
            if let (Some(project_id), Some(file_id)) = (f.project_id, f.file_id) {
                files.push(CfFileRef {
                    project_id,
                    file_id,
                    required: f.force.unwrap_or(true),
                    file_name: f.file_name,
                    url: f.url,
                });
            }
        } else if let Some(url) = f.url {
            files.push(CfFileRef {
                project_id: 0,
                file_id: files.len() as u64 + 1,
                required: true,
                file_name: f.file_name,
                url: Some(url),
            });
        }
    }

    if files.is_empty() {
        if let Ok(manifest_text) = read_zip_entry(&mut archive, "manifest.json") {
            if let Ok(cf) = parse_manifest_json(&manifest_text) {
                files = cf.files;
            }
        }
    }

    Ok((
        McbbsMeta {
            name: pack
                .name
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| "MCBBS Pack".into()),
            game_version,
            loader,
            loader_version,
            files,
            overrides: pack
                .overrides
                .unwrap_or_else(|| "overrides".into())
                .trim_matches('/')
                .to_string(),
        },
        zip_prefix,
    ))
}

async fn install_mcbbs(
    data: &[u8],
    name: Option<String>,
    java_path: Option<String>,
    on_progress: Option<ProgressFn>,
    resume_instance_id: Option<&str>,
) -> Result<Instance> {
    let (meta, zip_prefix) = read_mcbbs_meta(data)?;
    let cf = CfPackMeta {
        name: meta.name,
        version: None,
        author: None,
        game_version: meta.game_version,
        loader: meta.loader,
        loader_version: meta.loader_version,
        overrides: meta.overrides,
        files: meta.files,
    };
    install_from_cf_meta(
        data,
        cf,
        zip_prefix,
        name,
        java_path,
        on_progress,
        "mcbbs",
        resume_instance_id,
    )
    .await
}

async fn install_multimc_zip(
    data: &[u8],
    name: Option<String>,
    java_path: Option<String>,
    on_progress: Option<ProgressFn>,
    resume_instance_id: Option<&str>,
) -> Result<Instance> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    let meta = read_mmc_meta_from_zip(data)?;
    let instance_name = name.unwrap_or_else(|| meta.name.clone());
    let created = if let Some(id) = resume_instance_id {
        report(0.08, format!("Resuming instance {id}…"));
        report(0.10, format!("__INSTANCE_CREATED__:{id}"));
        db::set_install_stage(&state.pool, id, InstallStage::Installing).await?;
        db::get_instance(&state.pool, id).await?
    } else {
        report(0.08, format!("Creating instance {instance_name}…"));
        let created = db::create_instance(
            &state.pool,
            CreateInstanceRequest {
                name: instance_name.clone(),
                game_version: meta.game_version.clone(),
                loader: meta.loader,
                loader_version: meta.loader_version.clone(),
                icon: None,
            },
        )
        .await?;
        report(0.10, format!("__INSTANCE_CREATED__:{}", created.id));
        db::set_install_stage(&state.pool, &created.id, InstallStage::Installing).await?;
        created
    };
    let instance_dir = dirs::ensure_instance_dir(&resource, &created.path).await?;

    report(0.20, "Copying instance files…".into());
    extract_mmc_minecraft(data, &instance_dir, &meta.minecraft_prefix)?;

    report(0.78, "Installing Minecraft + loader…".into());
    install::install_instance(
        &created.id,
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
    let _ = crate::launcher::content::sync_instance_content_metadata(&created.id, false).await;
    let _ = db::set_instance_modpack_link(
        &state.pool,
        &created.id,
        None,
        None,
        None,
        Some("multimc"),
        Some(&instance_name),
    )
    .await;
    report(1.0, "Modpack installed".into());
    db::get_instance(&state.pool, &created.id).await
}

/// Import a MultiMC instance folder into a new AML instance.
pub async fn create_instance_from_mmc_folder(
    instance_folder: &str,
    name: Option<String>,
    java_path: Option<String>,
    on_progress: Option<ProgressFn>,
) -> Result<Instance> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };
    let folder = PathBuf::from(instance_folder);
    let (meta, minecraft_dir) = read_mmc_meta_from_dir(&folder)?;
    let instance_name = name.unwrap_or_else(|| meta.name.clone());
    report(0.08, format!("Creating instance {instance_name}…"));
    let created = db::create_instance(
        &state.pool,
        CreateInstanceRequest {
            name: instance_name.clone(),
            game_version: meta.game_version,
            loader: meta.loader,
            loader_version: meta.loader_version,
            icon: None,
        },
    )
    .await?;
    report(0.10, format!("__INSTANCE_CREATED__:{}", created.id));
    let instance_dir = dirs::ensure_instance_dir(&resource, &created.path).await?;
    report(0.20, "Copying instance files…".into());
    copy_dir_recursive(&minecraft_dir, &instance_dir).await?;
    report(0.78, "Installing Minecraft + loader…".into());
    install::install_instance(
        &created.id,
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
    let _ = crate::launcher::content::sync_instance_content_metadata(&created.id, false).await;
    let _ = db::set_instance_modpack_link(
        &state.pool,
        &created.id,
        None,
        None,
        None,
        Some("multimc"),
        Some(&instance_name),
    )
    .await;
    report(1.0, "Modpack installed".into());
    db::get_instance(&state.pool, &created.id).await
}

async fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    tokio::fs::create_dir_all(dst).await?;
    let mut stack = vec![src.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let mut rd = tokio::fs::read_dir(&dir).await?;
        while let Some(entry) = rd.next_entry().await? {
            let path = entry.path();
            let rel = path.strip_prefix(src).unwrap_or(&path);
            let target = dst.join(rel);
            if entry.file_type().await?.is_dir() {
                tokio::fs::create_dir_all(&target).await?;
                stack.push(path);
            } else {
                if let Some(parent) = target.parent() {
                    tokio::fs::create_dir_all(parent).await?;
                }
                tokio::fs::copy(&path, &target).await?;
            }
        }
    }
    Ok(())
}

fn pack_file_content_entry(
    instance_id: String,
    rel: &str,
    file_name: &str,
    file: &CfFileRef,
    download_url: Option<String>,
    sha1: Option<String>,
    size_bytes: Option<i64>,
    pending: bool,
) -> db::ContentEntry {
    let rel = rel.replace('\\', "/");
    let project_type = if rel.starts_with("resourcepacks/") {
        "resourcepack"
    } else if rel.starts_with("shaderpacks/") {
        "shader"
    } else if rel.starts_with("datapacks/") {
        "datapack"
    } else {
        "mod"
    };
    db::ContentEntry {
        id: format!("content:{}", uuid::Uuid::new_v4()),
        instance_id,
        relative_path: rel,
        file_name: file_name.to_string(),
        project_type: project_type.into(),
        project_id: (file.project_id > 0).then(|| format!("cf:{}", file.project_id)),
        version_id: (file.file_id > 0).then(|| file.file_id.to_string()),
        version_number: Some(file_name.to_string()),
        version_name: Some(file_name.to_string()),
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
        download_url,
    }
}
