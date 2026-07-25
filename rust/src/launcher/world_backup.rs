//! Singleplayer world zip backups (full + incremental) with restore chains.
//!
//! Layout: `{instance}/backups/worlds/{folder}/{stamp}_{full|inc}[_auto].zip`
//! Each zip embeds `_aml/meta.json` (+ optional `_aml/icon.png`).
//! World files are stored as `{folder}/…` (session.lock skipped).

use anyhow::{anyhow, Context, Result};
use chrono::Local;
use fs4::fs_std::FileExt;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use zip::write::FileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

use crate::state::db;
use crate::state::{resource_dir, try_state};

use super::dirs;
use super::worlds;

const MAX_BACKUPS_PER_WORLD: usize = 20;
const META_ENTRY: &str = "_aml/meta.json";
const ICON_ENTRY: &str = "_aml/icon.png";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackupKind {
    Full,
    Incremental,
}

impl BackupKind {
    pub fn parse(s: &str) -> Result<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "full" | "完整" => Ok(Self::Full),
            "incremental" | "inc" | "增量" => Ok(Self::Incremental),
            other => Err(anyhow!("未知备份类型: {other}")),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Full => "full",
            Self::Incremental => "incremental",
        }
    }

    fn file_tag(self) -> &'static str {
        match self {
            Self::Full => "full",
            Self::Incremental => "inc",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompressionPreset {
    Store,
    Fast,
    Balanced,
    Max,
}

impl CompressionPreset {
    pub fn parse(s: &str) -> Result<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "store" | "none" | "不压缩" => Ok(Self::Store),
            "fast" | "快速" => Ok(Self::Fast),
            "max" | "maximum" | "最大" => Ok(Self::Max),
            "balanced" | "default" | "均衡" | "" => Ok(Self::Balanced),
            other => Err(anyhow!("未知压缩档位: {other}")),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Store => "store",
            Self::Fast => "fast",
            Self::Balanced => "balanced",
            Self::Max => "max",
        }
    }

    fn zip_options(self) -> FileOptions {
        match self {
            Self::Store => FileOptions::default().compression_method(CompressionMethod::Stored),
            Self::Fast => FileOptions::default()
                .compression_method(CompressionMethod::Deflated)
                .compression_level(Some(1)),
            Self::Balanced => FileOptions::default()
                .compression_method(CompressionMethod::Deflated)
                .compression_level(Some(6)),
            Self::Max => FileOptions::default()
                .compression_method(CompressionMethod::Deflated)
                .compression_level(Some(9)),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct FileFinger {
    path: String,
    size: u64,
    mtime_ms: u64,
    /// Non-zero content fingerprint (sha256 truncated). `0` = unknown / legacy.
    #[serde(default)]
    hash: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BackupMeta {
    version: u32,
    id: String,
    kind: String,
    compression: String,
    auto: bool,
    created_at: String,
    #[serde(default)]
    parent_id: Option<String>,
    #[serde(default)]
    base_full_id: Option<String>,
    /// Complete world inventory at this backup point.
    files: Vec<FileFinger>,
    /// Paths removed since parent (incremental only).
    #[serde(default)]
    deleted: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct WorldBackupInfo {
    pub id: String,
    pub world_folder: String,
    pub file_name: String,
    pub created_at: String,
    pub size_bytes: u64,
    pub path: String,
    pub auto: bool,
    pub kind: String,
    pub compression: String,
    pub parent_id: Option<String>,
    pub base_full_id: Option<String>,
    pub icon_path: Option<String>,
    pub file_count: u32,
}

fn sanitize_folder(folder: &str) -> Result<String> {
    let f = folder.trim();
    if f.is_empty() || f.contains("..") || f.contains('/') || f.contains('\\') {
        return Err(anyhow!("非法的世界文件夹名"));
    }
    Ok(f.to_string())
}

fn backups_root(instance_dir: &Path) -> PathBuf {
    instance_dir.join("backups").join("worlds")
}

fn world_backup_dir(instance_dir: &Path, folder: &str) -> PathBuf {
    backups_root(instance_dir).join(folder)
}

fn world_dir(instance_dir: &Path, folder: &str) -> PathBuf {
    instance_dir.join("saves").join(folder)
}

fn icons_dir(backup_dir: &Path) -> PathBuf {
    backup_dir.join(".icons")
}

fn try_session_lock(world_path: &Path) -> Result<Option<File>> {
    let lock_path = world_path.join("session.lock");
    let file = match File::options()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
    {
        Ok(f) => f,
        Err(e) => return Err(anyhow!("无法打开 session.lock: {e}")),
    };
    let mut file = file;
    let _ = file.set_len(0);
    file.write_all("\u{2603}".as_bytes())?;
    match file.try_lock_exclusive() {
        Ok(()) => Ok(Some(file)),
        Err(_) => Ok(None),
    }
}

fn mtime_ms(path: &Path) -> u64 {
    path.metadata()
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn content_hash(path: &Path) -> u64 {
    use sha2::{Digest, Sha256};
    let Ok(mut file) = File::open(path) else {
        return 0;
    };
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    let mut total = 0u64;
    loop {
        let n = match file.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(_) => return 0,
        };
        hasher.update(&buf[..n]);
        total += n as u64;
        // Cap: large region files hash head 4MiB + size, still catches most edits.
        if total >= 4 * 1024 * 1024 {
            hasher.update(total.to_le_bytes());
            break;
        }
    }
    let digest = hasher.finalize();
    u64::from_le_bytes(digest[..8].try_into().unwrap_or([0; 8]))
}

fn collect_world_fingers(world_path: &Path) -> Result<Vec<FileFinger>> {
    let mut files = Vec::new();
    collect_fingers_inner(world_path, world_path, &mut files)?;
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

fn collect_fingers_inner(root: &Path, current: &Path, out: &mut Vec<FileFinger>) -> Result<()> {
    if !current.is_dir() {
        return Ok(());
    }
    for entry in std::fs::read_dir(current)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name();
        if name == "session.lock" {
            continue;
        }
        if path.is_dir() {
            collect_fingers_inner(root, &path, out)?;
        } else if path.is_file() {
            let Ok(rel) = path.strip_prefix(root) else {
                continue;
            };
            let rel = rel.to_string_lossy().replace('\\', "/");
            let size = path.metadata().map(|m| m.len()).unwrap_or(0);
            out.push(FileFinger {
                path: rel,
                size,
                mtime_ms: mtime_ms(&path),
                hash: content_hash(&path),
            });
        }
    }
    Ok(())
}

fn file_unchanged(prev: &FileFinger, curr: &FileFinger) -> bool {
    if prev.size != curr.size {
        return false;
    }
    if prev.hash != 0 && curr.hash != 0 {
        return prev.hash == curr.hash;
    }
    // Zip-rebuilt / legacy inventory without mtime: size-only.
    if prev.mtime_ms == 0 {
        return true;
    }
    prev.mtime_ms == curr.mtime_ms
}

fn fingers_from_zip(zip_path: &Path, folder: &str) -> Result<Vec<FileFinger>> {
    let file = File::open(zip_path)?;
    let mut archive = ZipArchive::new(file)?;
    let prefix = format!("{folder}/");
    let mut out = Vec::new();
    for i in 0..archive.len() {
        let entry = archive.by_index(i)?;
        if entry.is_dir() {
            continue;
        }
        let name = entry.name().replace('\\', "/");
        if name.starts_with("_aml/") {
            continue;
        }
        let rel = if let Some(rest) = name.strip_prefix(&prefix) {
            rest.to_string()
        } else {
            continue;
        };
        if rel.is_empty() || rel.contains("..") {
            continue;
        }
        out.push(FileFinger {
            path: rel,
            size: entry.size(),
            mtime_ms: 0,
            hash: 0,
        });
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(out)
}

fn resolve_parent_inventory(
    zip_path: &Path,
    meta: &BackupMeta,
    folder: &str,
) -> Result<Vec<FileFinger>> {
    if !meta.files.is_empty() {
        return Ok(meta.files.clone());
    }
    let from_zip = fingers_from_zip(zip_path, folder)?;
    if from_zip.is_empty() {
        return Err(anyhow!(
            "上一份备份没有可用的文件清单，请先再做一次完整备份后再增量"
        ));
    }
    Ok(from_zip)
}

fn is_timeline_backup(path: &Path) -> bool {
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    name.ends_with(".zip") && !name.contains("pre_restore")
}

fn read_meta_from_zip(zip_path: &Path) -> Option<BackupMeta> {
    let file = File::open(zip_path).ok()?;
    let mut archive = ZipArchive::new(file).ok()?;
    let mut entry = archive.by_name(META_ENTRY).ok()?;
    let mut buf = String::new();
    entry.read_to_string(&mut buf).ok()?;
    serde_json::from_str(&buf).ok()
}

fn legacy_meta_from_name(file_name: &str) -> Option<BackupMeta> {
    if !file_name.to_lowercase().ends_with(".zip") {
        return None;
    }
    let stem = file_name
        .trim_end_matches(".zip")
        .trim_end_matches(".ZIP")
        .to_string();
    let auto = stem.ends_with("_auto");
    let body = stem.trim_end_matches("_auto").to_string();
    // Accept both old `stamp` / `stamp_auto` and new `stamp_full` / `stamp_inc_auto`.
    let (kind, created_raw) = if body.ends_with("_inc") {
        ("incremental", body.trim_end_matches("_inc").to_string())
    } else if body.ends_with("_full") {
        ("full", body.trim_end_matches("_full").to_string())
    } else {
        ("full", body)
    };
    let created_at = created_raw.replace('_', " ");
    let id = stem.clone();
    Some(BackupMeta {
        version: 1,
        id: id.clone(),
        kind: kind.to_string(),
        compression: "balanced".into(),
        auto,
        created_at,
        parent_id: None,
        base_full_id: if kind == "full" { Some(id) } else { None },
        files: vec![],
        deleted: vec![],
    })
}

fn cache_icon(backup_dir: &Path, id: &str, world_path: &Path) -> Option<String> {
    let src = world_path.join("icon.png");
    if !src.is_file() {
        return None;
    }
    let icons = icons_dir(backup_dir);
    let _ = std::fs::create_dir_all(&icons);
    let dest = icons.join(format!("{id}.png"));
    std::fs::copy(&src, &dest).ok()?;
    Some(dest.to_string_lossy().into_owned())
}

fn icon_path_for(backup_dir: &Path, id: &str) -> Option<String> {
    let p = icons_dir(backup_dir).join(format!("{id}.png"));
    if p.is_file() {
        Some(p.to_string_lossy().into_owned())
    } else {
        None
    }
}

fn info_from_zip(world_folder: &str, backup_dir: &Path, path: &Path) -> Option<WorldBackupInfo> {
    let file_name = path.file_name()?.to_string_lossy().to_string();
    if !file_name.to_lowercase().ends_with(".zip") {
        return None;
    }
    let meta = read_meta_from_zip(path).or_else(|| legacy_meta_from_name(&file_name))?;
    let size_bytes = path.metadata().ok()?.len();
    Some(WorldBackupInfo {
        id: meta.id.clone(),
        world_folder: world_folder.to_string(),
        file_name,
        created_at: meta.created_at,
        size_bytes,
        path: path.to_string_lossy().into_owned(),
        auto: meta.auto,
        kind: meta.kind,
        compression: meta.compression,
        parent_id: meta.parent_id,
        base_full_id: meta.base_full_id,
        icon_path: icon_path_for(backup_dir, &meta.id),
        file_count: meta.files.len() as u32,
    })
}

fn list_backup_metas(backup_dir: &Path) -> Result<Vec<(PathBuf, BackupMeta)>> {
    if !backup_dir.is_dir() {
        return Ok(vec![]);
    }
    let mut out = Vec::new();
    for entry in std::fs::read_dir(backup_dir)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() || !is_timeline_backup(&path) {
            continue;
        }
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if let Some(meta) = read_meta_from_zip(&path).or_else(|| legacy_meta_from_name(name)) {
            out.push((path, meta));
        }
    }
    out.sort_by(|a, b| a.1.created_at.cmp(&b.1.created_at));
    Ok(out)
}

fn find_latest_full(metas: &[(PathBuf, BackupMeta)]) -> Option<&(PathBuf, BackupMeta)> {
    metas.iter().rev().find(|(_, m)| m.kind == "full")
}

fn find_latest_any(metas: &[(PathBuf, BackupMeta)]) -> Option<&(PathBuf, BackupMeta)> {
    metas.last()
}

fn prune_old_backups(backup_dir: &Path) -> Result<()> {
    let mut metas = list_backup_metas(backup_dir)?;
    if metas.len() <= MAX_BACKUPS_PER_WORLD {
        return Ok(());
    }
    // Remove oldest first; if removing a full, cascade its incrementals.
    while metas.len() > MAX_BACKUPS_PER_WORLD {
        let Some((oldest_path, oldest_meta)) = metas.first().cloned() else {
            break;
        };
        let remove_ids: HashSet<String> = if oldest_meta.kind == "full" {
            metas
                .iter()
                .filter(|(_, m)| {
                    m.id == oldest_meta.id
                        || m.base_full_id.as_deref() == Some(oldest_meta.id.as_str())
                })
                .map(|(_, m)| m.id.clone())
                .collect()
        } else {
            HashSet::from([oldest_meta.id.clone()])
        };
        metas.retain(|(path, meta)| {
            if remove_ids.contains(&meta.id) {
                let _ = std::fs::remove_file(path);
                let icon = icons_dir(backup_dir).join(format!("{}.png", meta.id));
                let _ = std::fs::remove_file(icon);
                false
            } else {
                true
            }
        });
        let _ = oldest_path; // already handled via retain
    }
    Ok(())
}

fn write_zip_bytes(zip: &mut ZipWriter<File>, name: &str, data: &[u8], opts: FileOptions) -> Result<()> {
    zip.start_file(name, opts)?;
    zip.write_all(data)?;
    Ok(())
}

fn add_world_file(
    zip: &mut ZipWriter<File>,
    folder: &str,
    world_path: &Path,
    rel: &str,
    opts: FileOptions,
) -> Result<()> {
    let path = world_path.join(rel.replace('/', std::path::MAIN_SEPARATOR_STR));
    let mut f = File::open(&path).with_context(|| format!("读取 {}", path.display()))?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)?;
    write_zip_bytes(zip, &format!("{folder}/{rel}"), &buf, opts)?;
    Ok(())
}

pub async fn backup_world(
    instance_id: &str,
    folder: &str,
    auto: bool,
    kind: BackupKind,
    compression: CompressionPreset,
) -> Result<WorldBackupInfo> {
    let folder = sanitize_folder(folder)?;
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let world_path = world_dir(&instance_dir, &folder);
    if !world_path.join("level.dat").is_file() {
        return Err(anyhow!("找不到世界存档: {folder}"));
    }

    let lock = try_session_lock(&world_path)?;
    if lock.is_none() {
        return Err(anyhow!("世界正在游戏中使用，无法备份"));
    }
    let _lock = lock;

    let backup_dir = world_backup_dir(&instance_dir, &folder);
    tokio::fs::create_dir_all(&backup_dir).await?;

    let existing = list_backup_metas(&backup_dir)?;
    let current_files = collect_world_fingers(&world_path)?;

    let (parent_id, base_full_id, deleted, files_to_pack) = match kind {
        BackupKind::Full => {
            let files_to_pack: Vec<String> = current_files.iter().map(|f| f.path.clone()).collect();
            (None, None, Vec::new(), files_to_pack)
        }
        BackupKind::Incremental => {
            let latest = find_latest_any(&existing)
                .ok_or_else(|| anyhow!("没有可用基准备份，请先创建完整备份"))?;
            let latest_full = find_latest_full(&existing)
                .ok_or_else(|| anyhow!("没有完整备份，请先创建完整备份"))?;
            let parent_meta = &latest.1;
            let parent_files =
                resolve_parent_inventory(&latest.0, parent_meta, &folder)?;
            let parent_map: HashMap<&str, &FileFinger> =
                parent_files.iter().map(|f| (f.path.as_str(), f)).collect();
            let current_map: HashMap<&str, &FileFinger> =
                current_files.iter().map(|f| (f.path.as_str(), f)).collect();

            let mut changed = Vec::new();
            for f in &current_files {
                match parent_map.get(f.path.as_str()) {
                    Some(prev) if file_unchanged(prev, f) => {}
                    _ => changed.push(f.path.clone()),
                }
            }
            let deleted: Vec<String> = parent_files
                .iter()
                .filter(|f| !current_map.contains_key(f.path.as_str()))
                .map(|f| f.path.clone())
                .collect();

            if changed.is_empty() && deleted.is_empty() {
                return Err(anyhow!("世界相对上一份备份没有变化"));
            }

            eprintln!(
                "[AML] incremental backup: {} changed, {} deleted (of {} files)",
                changed.len(),
                deleted.len(),
                current_files.len()
            );

            let base_id = latest_full
                .1
                .base_full_id
                .clone()
                .unwrap_or_else(|| latest_full.1.id.clone());
            (
                Some(parent_meta.id.clone()),
                Some(base_id),
                deleted,
                changed,
            )
        }
    };

    let stamp = Local::now().format("%Y-%m-%d_%H-%M-%S").to_string();
    let id = if auto {
        format!("{stamp}_{}_auto", kind.file_tag())
    } else {
        format!("{stamp}_{}", kind.file_tag())
    };
    let file_name = format!("{id}.zip");
    let zip_path = backup_dir.join(&file_name);
    let created_at = stamp.replace('_', " ");

    let base_full_id = match kind {
        BackupKind::Full => Some(id.clone()),
        BackupKind::Incremental => base_full_id,
    };

    let meta = BackupMeta {
        version: 1,
        id: id.clone(),
        kind: kind.as_str().to_string(),
        compression: compression.as_str().to_string(),
        auto,
        created_at: created_at.clone(),
        parent_id: parent_id.clone(),
        base_full_id: base_full_id.clone(),
        files: current_files.clone(),
        deleted: deleted.clone(),
    };
    let meta_bytes = serde_json::to_vec_pretty(&meta)?;

    let opts = compression.zip_options();
    let file = File::create(&zip_path)
        .with_context(|| format!("无法创建备份文件 {}", zip_path.display()))?;
    let mut zip = ZipWriter::new(file);
    write_zip_bytes(&mut zip, META_ENTRY, &meta_bytes, opts)?;

    if world_path.join("icon.png").is_file() {
        let mut icon_buf = Vec::new();
        File::open(world_path.join("icon.png"))?.read_to_end(&mut icon_buf)?;
        write_zip_bytes(&mut zip, ICON_ENTRY, &icon_buf, opts)?;
    }

    for rel in &files_to_pack {
        add_world_file(&mut zip, &folder, &world_path, rel, opts)?;
    }
    zip.finish()?;

    let icon_path = cache_icon(&backup_dir, &id, &world_path);
    prune_old_backups(&backup_dir)?;

    let size_bytes = zip_path.metadata()?.len();
    Ok(WorldBackupInfo {
        id,
        world_folder: folder,
        file_name,
        created_at,
        size_bytes,
        path: zip_path.to_string_lossy().into_owned(),
        auto,
        kind: kind.as_str().to_string(),
        compression: compression.as_str().to_string(),
        parent_id,
        base_full_id,
        icon_path,
        file_count: current_files.len() as u32,
    })
}

pub async fn list_world_backups(
    instance_id: &str,
    folder: &str,
) -> Result<Vec<WorldBackupInfo>> {
    let folder = sanitize_folder(folder)?;
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let backup_dir = world_backup_dir(&instance_dir, &folder);
    if !backup_dir.is_dir() {
        return Ok(vec![]);
    }
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&backup_dir)? {
        let entry = entry?;
        let path = entry.path();
        if !is_timeline_backup(&path) {
            continue;
        }
        if let Some(info) = info_from_zip(&folder, &backup_dir, &path) {
            out.push(info);
        }
    }
    // Newest first for timeline UI.
    out.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(out)
}

fn resolve_restore_chain(
    backup_dir: &Path,
    target_path: &Path,
) -> Result<Vec<PathBuf>> {
    let target_meta = read_meta_from_zip(target_path)
        .or_else(|| {
            target_path
                .file_name()
                .and_then(|s| s.to_str())
                .and_then(legacy_meta_from_name)
        })
        .ok_or_else(|| anyhow!("无法读取备份元数据"))?;

    if target_meta.kind != "incremental" {
        return Ok(vec![target_path.to_path_buf()]);
    }

    let all = list_backup_metas(backup_dir)?;
    let by_id: HashMap<String, PathBuf> = all
        .iter()
        .map(|(p, m)| (m.id.clone(), p.clone()))
        .collect();

    let mut chain_rev = vec![target_path.to_path_buf()];
    let mut cursor = target_meta.parent_id.clone();
    let mut guard = 0;
    while let Some(pid) = cursor {
        guard += 1;
        if guard > 64 {
            return Err(anyhow!("增量备份链过长或存在环"));
        }
        let path = by_id
            .get(&pid)
            .cloned()
            .ok_or_else(|| anyhow!("缺少父备份: {pid}"))?;
        let meta = read_meta_from_zip(&path)
            .or_else(|| {
                path.file_name()
                    .and_then(|s| s.to_str())
                    .and_then(legacy_meta_from_name)
            })
            .ok_or_else(|| anyhow!("无法读取父备份元数据: {pid}"))?;
        chain_rev.push(path);
        if meta.kind == "full" {
            break;
        }
        cursor = meta.parent_id;
    }

    if chain_rev
        .last()
        .and_then(|p| read_meta_from_zip(p))
        .map(|m| m.kind != "full")
        .unwrap_or(true)
    {
        // Last should be full; if legacy incremental without chain, fail clearly.
        let last_kind = chain_rev
            .last()
            .and_then(|p| {
                read_meta_from_zip(p).or_else(|| {
                    p.file_name()
                        .and_then(|s| s.to_str())
                        .and_then(legacy_meta_from_name)
                })
            })
            .map(|m| m.kind);
        if last_kind.as_deref() != Some("full") {
            return Err(anyhow!("无法构建完整→增量恢复链，请先保留对应的完整备份"));
        }
    }

    chain_rev.reverse();
    Ok(chain_rev)
}

fn extract_world_zip(zip_path: &Path, world_path: &Path, folder: &str) -> Result<Vec<String>> {
    let file = File::open(zip_path)?;
    let mut archive = ZipArchive::new(file)?;
    let prefix = format!("{folder}/");
    let mut written = Vec::new();
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        if entry.is_dir() {
            continue;
        }
        let name = entry.name().replace('\\', "/");
        if name.starts_with("_aml/") {
            continue;
        }
        let rel = if let Some(rest) = name.strip_prefix(&prefix) {
            rest.to_string()
        } else if !name.contains('/') {
            name
        } else {
            continue;
        };
        if rel.is_empty() || rel.contains("..") {
            continue;
        }
        let out = world_path.join(rel.replace('/', std::path::MAIN_SEPARATOR_STR));
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut outfile = File::create(&out)?;
        std::io::copy(&mut entry, &mut outfile)?;
        written.push(rel);
    }
    Ok(written)
}

fn apply_incremental_deletes(world_path: &Path, zip_path: &Path) -> Result<()> {
    let Some(meta) = read_meta_from_zip(zip_path) else {
        return Ok(());
    };
    for rel in meta.deleted {
        if rel.is_empty() || rel.contains("..") {
            continue;
        }
        let path = world_path.join(rel.replace('/', std::path::MAIN_SEPARATOR_STR));
        if path.is_file() {
            let _ = std::fs::remove_file(path);
        }
    }
    Ok(())
}

fn backup_world_at_path(
    world_path: &Path,
    folder: &str,
    zip_path: &Path,
    compression: CompressionPreset,
) -> Result<()> {
    let files = collect_world_fingers(world_path)?;
    let opts = compression.zip_options();
    let file = File::create(zip_path)?;
    let mut zip = ZipWriter::new(file);
    let meta = BackupMeta {
        version: 1,
        id: zip_path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "pre_restore".into()),
        kind: "full".into(),
        compression: compression.as_str().to_string(),
        auto: false,
        created_at: Local::now().format("%Y-%m-%d %H-%M-%S").to_string(),
        parent_id: None,
        base_full_id: None,
        files: files.clone(),
        deleted: vec![],
    };
    write_zip_bytes(&mut zip, META_ENTRY, &serde_json::to_vec_pretty(&meta)?, opts)?;
    for f in &files {
        add_world_file(&mut zip, folder, world_path, &f.path, opts)?;
    }
    zip.finish()?;
    Ok(())
}

pub async fn restore_world_backup(instance_id: &str, backup_path: &str) -> Result<()> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let zip_path = PathBuf::from(backup_path);
    if !zip_path.is_file() {
        return Err(anyhow!("备份文件不存在"));
    }
    let backups = backups_root(&instance_dir);
    let zip_canon = zip_path
        .canonicalize()
        .unwrap_or_else(|_| zip_path.clone());
    let backups_canon = backups.canonicalize().unwrap_or(backups);
    if !zip_canon.starts_with(&backups_canon) {
        return Err(anyhow!("备份路径不属于该实例"));
    }

    let folder = zip_path
        .parent()
        .and_then(|p| p.file_name())
        .map(|s| s.to_string_lossy().into_owned())
        .ok_or_else(|| anyhow!("无法解析世界文件夹"))?;
    let folder = sanitize_folder(&folder)?;
    let world_path = world_dir(&instance_dir, &folder);
    let backup_dir = world_backup_dir(&instance_dir, &folder);

    if world_path.exists() {
        let lock = try_session_lock(&world_path)?;
        if lock.is_none() {
            return Err(anyhow!("世界正在游戏中使用，无法恢复"));
        }
        drop(lock);
        let stamp = Local::now().format("%Y-%m-%d_%H-%M-%S").to_string();
        let safety = backup_dir.join(format!("{stamp}_full_pre_restore.zip"));
        tokio::fs::create_dir_all(&backup_dir).await?;
        let _ = backup_world_at_path(&world_path, &folder, &safety, CompressionPreset::Fast);
        tokio::fs::remove_dir_all(&world_path).await?;
    }

    tokio::fs::create_dir_all(&world_path).await?;
    let chain = resolve_restore_chain(&backup_dir, &zip_path)?;
    for (idx, part) in chain.iter().enumerate() {
        extract_world_zip(part, &world_path, &folder)?;
        if idx > 0 {
            apply_incremental_deletes(&world_path, part)?;
        }
    }
    Ok(())
}

pub async fn delete_world_backup(instance_id: &str, backup_path: &str) -> Result<()> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let zip_path = PathBuf::from(backup_path);
    let backups = backups_root(&instance_dir);
    let zip_canon = zip_path
        .canonicalize()
        .unwrap_or_else(|_| zip_path.clone());
    let backups_canon = backups.canonicalize().unwrap_or(backups);
    if !zip_canon.starts_with(&backups_canon) {
        return Err(anyhow!("备份路径不属于该实例"));
    }

    let backup_dir = zip_path
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."));
    let meta = read_meta_from_zip(&zip_path).or_else(|| {
        zip_path
            .file_name()
            .and_then(|s| s.to_str())
            .and_then(legacy_meta_from_name)
    });

    let mut to_remove = vec![zip_path.clone()];
    if let Some(meta) = meta {
        if meta.kind == "full" {
            let all = list_backup_metas(&backup_dir)?;
            for (path, m) in all {
                if m.base_full_id.as_deref() == Some(meta.id.as_str()) && m.id != meta.id {
                    to_remove.push(path);
                }
            }
        }
        let icon = icons_dir(&backup_dir).join(format!("{}.png", meta.id));
        let _ = std::fs::remove_file(icon);
    }

    for path in to_remove {
        if path.is_file() {
            tokio::fs::remove_file(&path).await?;
        }
    }
    Ok(())
}

/// Called after Minecraft exits.
pub async fn auto_backup_after_exit(
    instance_id: &str,
    quick_play_world: Option<String>,
) -> Result<()> {
    let state = try_state()?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    if !instance.auto_backup_worlds {
        return Ok(());
    }

    let target = if let Some(folder) = quick_play_world.filter(|s| !s.trim().is_empty()) {
        Some(folder)
    } else {
        let worlds = worlds::list_instance_worlds(instance_id)
            .await
            .unwrap_or_default();
        worlds
            .into_iter()
            .find(|w| w.kind == "singleplayer")
            .map(|w| w.folder)
    };

    let Some(folder) = target else {
        return Ok(());
    };

    let resource = resource_dir().await?;
    let _ = dirs::instance_dir(&resource, &instance.path);

    match backup_world(
        instance_id,
        &folder,
        true,
        BackupKind::Full,
        CompressionPreset::Balanced,
    )
    .await
    {
        Ok(info) => {
            eprintln!(
                "[AML] auto-backup world `{folder}` → {} ({} bytes, {})",
                info.file_name, info.size_bytes, info.kind
            );
        }
        Err(e) => {
            eprintln!("[AML] auto-backup world `{folder}` skipped: {e:#}");
        }
    }
    Ok(())
}
