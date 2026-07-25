use anyhow::{Context, Result};
use std::io::{Read, Write};
use std::path::Path;
use zip::write::FileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::launcher::dirs;
use crate::launcher::download::ProgressFn;
use crate::state::db;
use crate::state::models::ModLoader;
use crate::state::{resource_dir, try_state};

use super::export_common::{
    collect_pack_content_files, filter_paths_by_rel, sanitize_pack_name, ExportIncludes,
};

/// Export an instance as a MultiMC zip.
///
/// Layout:
/// ```text
/// {name}/
///   instance.cfg
///   mmc-pack.json
///   minecraft/
///     mods/…
///     config/…
/// ```
pub async fn export_instance_multimc(
    instance_id: &str,
    export_path: &str,
    pack_name: Option<String>,
    includes: ExportIncludes,
    path_filter: Option<std::collections::HashSet<String>>,
    on_progress: Option<ProgressFn>,
) -> Result<()> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let display_name = pack_name
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
    let folder = sanitize_pack_name(&display_name);

    let mmc_pack = build_mmc_pack_json(
        &instance.game_version,
        ModLoader::parse(&instance.loader),
        instance.loader_version.as_deref(),
    )?;
    let instance_cfg = format!(
        "InstanceType=OneSix\nname={}\n",
        display_name.replace('\n', " ")
    );

    report(0.15, "Writing MultiMC pack…".into());
    if let Some(parent) = Path::new(export_path).parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let file = std::fs::File::create(export_path)
        .with_context(|| format!("无法创建导出文件 {export_path}"))?;
    let mut zip = ZipWriter::new(file);
    let opts = FileOptions::default().compression_method(CompressionMethod::Deflated);

    zip.start_file(format!("{folder}/instance.cfg"), opts)?;
    zip.write_all(instance_cfg.as_bytes())?;
    zip.start_file(format!("{folder}/mmc-pack.json"), opts)?;
    zip.write_all(serde_json::to_vec_pretty(&mmc_pack)?.as_slice())?;

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
        zip.start_file(format!("{folder}/minecraft/{rel}"), opts)?;
        zip.write_all(&buf)?;
    }

    zip.finish()?;
    report(1.0, "Export complete".into());
    Ok(())
}

fn build_mmc_pack_json(
    game_version: &str,
    loader: ModLoader,
    loader_version: Option<&str>,
) -> Result<serde_json::Value> {
    let mut components = vec![serde_json::json!({
        "uid": "net.minecraft",
        "version": game_version,
        "important": true,
        "cachedName": "Minecraft",
        "cachedVersion": game_version,
    })];

    if let Some(ver) = loader_version.filter(|v| !v.is_empty()) {
        match loader {
            ModLoader::Fabric => {
                components.push(serde_json::json!({
                    "uid": "net.fabricmc.fabric-loader",
                    "version": ver,
                    "cachedName": "Fabric Loader",
                    "cachedVersion": ver,
                }));
            }
            ModLoader::Quilt => {
                components.push(serde_json::json!({
                    "uid": "org.quiltmc.quilt-loader",
                    "version": ver,
                    "cachedName": "Quilt Loader",
                    "cachedVersion": ver,
                }));
            }
            ModLoader::Forge => {
                components.push(serde_json::json!({
                    "uid": "net.minecraftforge",
                    "version": ver,
                    "cachedName": "Forge",
                    "cachedVersion": ver,
                }));
            }
            ModLoader::NeoForge => {
                components.push(serde_json::json!({
                    "uid": "net.neoforged",
                    "version": ver,
                    "cachedName": "NeoForge",
                    "cachedVersion": ver,
                }));
            }
            ModLoader::Vanilla => {}
        }
    }

    Ok(serde_json::json!({
        "components": components,
        "formatVersion": 1,
    }))
}
