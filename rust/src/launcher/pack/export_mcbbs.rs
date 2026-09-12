use anyhow::{Context, Result};
use serde::Serialize;
use std::io::{Read, Write};
use std::path::Path;
use zip::write::FileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::launcher::dirs;
use crate::launcher::download::ProgressFn;
use crate::state::db;
use crate::state::models::ModLoader;
use crate::state::{resource_dir, try_state};

use super::export_common::{collect_pack_content_files, filter_paths_by_rel, ExportIncludes};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct McbbsPackmetaOut {
    manifest_type: String,
    manifest_version: i32,
    name: String,
    version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    author: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    file_api: String,
    url: String,
    force_update: bool,
    origin: Vec<serde_json::Value>,
    addons: Vec<McbbsAddonOut>,
    libraries: Vec<serde_json::Value>,
    files: Vec<serde_json::Value>,
    overrides: String,
}

#[derive(Serialize)]
struct McbbsAddonOut {
    id: String,
    version: String,
}

/// Export an instance as an MCBBS zip.
///
/// Content is embedded under `overrides/` (offline-friendly). Remote CurseForge
/// file entries are omitted unless we later track CF project/file IDs.
pub async fn export_instance_mcbbs(
    instance_id: &str,
    export_path: &str,
    pack_name: Option<String>,
    version: Option<String>,
    description: Option<String>,
    includes: ExportIncludes,
    path_filter: Option<std::collections::HashSet<String>>,
    on_progress: Option<ProgressFn>,
) -> Result<()> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let pack_name = pack_name
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| instance.name.clone());
    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    report(0.05, "Collecting files…".into());
    let files = filter_paths_by_rel(
        &instance_dir,
        collect_pack_content_files(&instance_dir, &includes)?,
        path_filter.as_ref(),
    );

    let mut addons = vec![McbbsAddonOut {
        id: "game".into(),
        version: instance.game_version.clone(),
    }];
    let loader = ModLoader::parse(&instance.loader);
    if let Some(ver) = instance.loader_version.as_deref().filter(|v| !v.is_empty()) {
        let id = match loader {
            ModLoader::Fabric => Some("fabric"),
            ModLoader::Quilt => Some("quilt"),
            ModLoader::Forge => Some("forge"),
            ModLoader::NeoForge => Some("neoforge"),
            ModLoader::Vanilla => None,
        };
        if let Some(id) = id {
            addons.push(McbbsAddonOut {
                id: id.into(),
                version: ver.to_string(),
            });
        }
    }

    let packmeta = McbbsPackmetaOut {
        manifest_type: "minecraftModpack".into(),
        manifest_version: 2,
        name: pack_name,
        version: version.unwrap_or_else(|| "1.0.0".into()),
        author: Some("AML".into()),
        description,
        file_api: String::new(),
        url: String::new(),
        force_update: false,
        origin: Vec::new(),
        addons,
        libraries: Vec::new(),
        files: Vec::new(),
        overrides: "overrides".into(),
    };

    report(0.15, "Writing MCBBS pack…".into());
    if let Some(parent) = Path::new(export_path).parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let file = std::fs::File::create(export_path)
        .with_context(|| format!("无法创建导出文件 {export_path}"))?;
    let mut zip = ZipWriter::new(file);
    let opts = FileOptions::default().compression_method(CompressionMethod::Deflated);

    let meta_bytes = serde_json::to_vec_pretty(&packmeta)?;
    zip.start_file("mcbbs.packmeta", opts)?;
    zip.write_all(&meta_bytes)?;

    let total = files.len().max(1) as f64;
    for (i, path) in files.iter().enumerate() {
        report(
            0.20 + (i as f64 / total) * 0.75,
            format!("Packing {}…", path.display()),
        );
        let Ok(rel) = path.strip_prefix(&instance_dir) else {
            continue;
        };
        let rel = rel.to_string_lossy().replace('\\', "/");
        if !path.is_file() {
            continue;
        }
        let mut f = std::fs::File::open(path)?;
        let mut buf = Vec::new();
        f.read_to_end(&mut buf)?;
        zip.start_file(format!("overrides/{rel}"), opts)?;
        zip.write_all(&buf)?;
    }

    zip.finish()?;
    report(1.0, "Export complete".into());
    Ok(())
}
