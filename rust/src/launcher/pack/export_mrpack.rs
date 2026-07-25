use anyhow::{Context, Result};
use serde::Deserialize;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use zip::write::FileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::config::modrinth_api_url;
use crate::launcher::dirs;
use crate::launcher::download::ProgressFn;
use crate::state::db;
use crate::state::models::ModLoader;
use crate::state::{resource_dir, try_state};

use super::export_common::{
    collect_override_candidates, filter_paths_by_rel, relative_path_allowed,
    should_skip_export_path, ExportIncludes,
};

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct MrpackIndexOut {
    game: String,
    format_version: i32,
    version_id: String,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    summary: Option<String>,
    files: Vec<MrpackFileOut>,
    dependencies: serde_json::Map<String, serde_json::Value>,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct MrpackFileOut {
    path: String,
    hashes: serde_json::Map<String, serde_json::Value>,
    downloads: Vec<String>,
    file_size: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    env: Option<serde_json::Map<String, serde_json::Value>>,
}

#[derive(Deserialize)]
struct ModrinthVersionApi {
    id: String,
    files: Vec<ModrinthVersionFileApi>,
}

#[derive(Deserialize)]
struct ModrinthVersionFileApi {
    url: String,
    filename: String,
    size: u64,
    hashes: ModrinthHashesApi,
    #[serde(default)]
    primary: Option<bool>,
}

#[derive(Deserialize)]
struct ModrinthHashesApi {
    sha1: Option<String>,
    sha512: Option<String>,
}

/// Export an instance to a `.mrpack` archive.
pub async fn export_instance_mrpack(
    instance_id: &str,
    export_path: &str,
    pack_name: Option<String>,
    version_id: Option<String>,
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

    report(0.05, "Collecting content…".into());
    let content = db::list_content_for_instance(&state.pool, instance_id).await?;
    let client = crate::launcher::manifest::http_client()?;

    let mut files_out = Vec::new();
    let mut embedded_rel_paths = std::collections::HashSet::new();
    let total = content.len().max(1) as f64;

    for (i, entry) in content.iter().enumerate() {
        report(
            0.05 + (i as f64 / total) * 0.45,
            format!("Resolving {}…", entry.relative_path),
        );
        if !relative_path_allowed(&entry.relative_path, &includes, path_filter.as_ref()) {
            continue;
        }
        let Some(version_id) = entry.version_id.as_deref() else {
            continue;
        };
        let url = format!("{}version/{version_id}", modrinth_api_url());
        let Ok(resp) = client.get(&url).send().await else {
            continue;
        };
        if !resp.status().is_success() {
            continue;
        }
        let Ok(version) = resp.json::<ModrinthVersionApi>().await else {
            continue;
        };
        let Some(primary) = version
            .files
            .iter()
            .find(|f| f.primary.unwrap_or(false))
            .or_else(|| version.files.first())
        else {
            continue;
        };

        let mut hashes = serde_json::Map::new();
        if let Some(sha1) = &primary.hashes.sha1 {
            hashes.insert("sha1".into(), serde_json::Value::String(sha1.clone()));
        }
        if let Some(sha512) = &primary.hashes.sha512 {
            hashes.insert("sha512".into(), serde_json::Value::String(sha512.clone()));
        }
        let mut env = serde_json::Map::new();
        env.insert("client".into(), serde_json::Value::String("required".into()));
        env.insert("server".into(), serde_json::Value::String("required".into()));

        files_out.push(MrpackFileOut {
            path: entry.relative_path.replace('\\', "/"),
            hashes,
            downloads: vec![primary.url.clone()],
            file_size: primary.size,
            env: Some(env),
        });
        embedded_rel_paths.insert(entry.relative_path.replace('\\', "/"));
        let _ = version.id;
        let _ = primary.filename;
    }

    let mut deps = serde_json::Map::new();
    deps.insert(
        "minecraft".into(),
        serde_json::Value::String(instance.game_version.clone()),
    );
    match ModLoader::parse(&instance.loader) {
        ModLoader::Fabric => {
            if let Some(v) = &instance.loader_version {
                deps.insert(
                    "fabric-loader".into(),
                    serde_json::Value::String(v.clone()),
                );
            }
        }
        ModLoader::Quilt => {
            if let Some(v) = &instance.loader_version {
                deps.insert(
                    "quilt-loader".into(),
                    serde_json::Value::String(v.clone()),
                );
            }
        }
        ModLoader::Forge => {
            if let Some(v) = &instance.loader_version {
                deps.insert("forge".into(), serde_json::Value::String(v.clone()));
            }
        }
        ModLoader::NeoForge => {
            if let Some(v) = &instance.loader_version {
                deps.insert("neoforge".into(), serde_json::Value::String(v.clone()));
            }
        }
        ModLoader::Vanilla => {}
    }

    let index = MrpackIndexOut {
        game: "minecraft".into(),
        format_version: 1,
        version_id: version_id.unwrap_or_else(|| "1.0.0".into()),
        name: pack_name,
        summary: description,
        files: files_out,
        dependencies: deps,
    };

    report(0.55, "Writing mrpack…".into());
    if let Some(parent) = Path::new(export_path).parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let file = std::fs::File::create(export_path)
        .with_context(|| format!("无法创建导出文件 {export_path}"))?;
    let mut zip = ZipWriter::new(file);
    let opts = FileOptions::default().compression_method(CompressionMethod::Deflated);

    let index_bytes = serde_json::to_vec_pretty(&index)?;
    zip.start_file("modrinth.index.json", opts)?;
    zip.write_all(&index_bytes)?;

    // Bundle remaining interesting files into overrides/ (configs, unmatched mods, etc.)
    let mut override_files: Vec<PathBuf> = Vec::new();
    collect_override_candidates(
        &instance_dir,
        &instance_dir,
        &embedded_rel_paths,
        &includes,
        &mut override_files,
    )?;
    let override_files = filter_paths_by_rel(&instance_dir, override_files, path_filter.as_ref());

    let total_ov = override_files.len().max(1) as f64;
    for (i, path) in override_files.iter().enumerate() {
        report(
            0.55 + (i as f64 / total_ov) * 0.40,
            format!("Packing {}…", path.display()),
        );
        let Ok(rel) = path.strip_prefix(&instance_dir) else {
            continue;
        };
        let rel = rel.to_string_lossy().replace('\\', "/");
        if embedded_rel_paths.contains(&rel) {
            continue;
        }
        if should_skip_export_path(&rel, &includes) {
            continue;
        }
        if !path.is_file() {
            continue;
        }
        let mut f = std::fs::File::open(path)?;
        let mut buf = Vec::new();
        f.read_to_end(&mut buf)?;
        zip.start_file(format!("overrides/{rel}"), opts)?;
        zip.write_all(&buf)?;
    }

    // Prefer packing instance icon.
    let icon = instance_dir.join("icon.png");
    if icon.is_file() {
        let bytes = std::fs::read(&icon)?;
        zip.start_file("overrides/icon.png", opts)?;
        zip.write_all(&bytes)?;
    }

    zip.finish()?;
    report(1.0, "Export complete".into());
    Ok(())
}
