//! Modpack import/export pipeline (Modrinth / CurseForge / MultiMC / MCBBS).

mod curseforge;
pub use curseforge::{download_cf_file, download_cf_file_to_path};
mod detect;
mod export_common;
mod export_mcbbs;
mod export_mmc;
mod export_mrpack;
mod icon;
mod import;
mod mmc;

pub use detect::{detect_pack_bytes, detect_pack_file, PackKind};
pub use export_common::{
    enrich_categories_with_content, summarize_export_content, ExportIncludes, PackContentCategory,
    PackContentFile,
};
pub use export_mcbbs::export_instance_mcbbs;
pub use export_mmc::export_instance_multimc;
pub use export_mrpack::export_instance_mrpack;
pub use icon::{
    find_pack_icon_bytes, try_extract_pack_icon_from_archive, try_extract_pack_icon_to,
};
pub use import::{
    create_instance_from_mmc_folder, create_instance_from_pack_file_resumable, preview_pack_file,
    PackImportPreview,
};

use anyhow::{anyhow, Result};
use crate::config::CURSEFORGE_API_KEY_DEFAULT;
use crate::launcher::dirs;
use crate::launcher::download::ProgressFn;
use crate::state::db;
use crate::state::{resource_dir, try_state};

/// Resolve CurseForge API key: env override → built-in default.
pub fn curseforge_api_key() -> String {
    if let Ok(key) = std::env::var("AML_CURSEFORGE_API_KEY") {
        let trimmed = key.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    CURSEFORGE_API_KEY_DEFAULT.to_string()
}

/// Preview which content categories would be exported from an instance.
pub async fn preview_instance_export(instance_id: &str) -> Result<Vec<PackContentCategory>> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let mut categories = summarize_export_content(&instance_dir)?;
    let content = db::list_content_for_instance(&state.pool, instance_id).await?;
    enrich_categories_with_content(&mut categories, &content);
    Ok(categories)
}

/// Unified pack export. `format` is one of: `mrpack`, `multimc`, `mcbbs`.
pub async fn export_instance_pack(
    instance_id: &str,
    export_path: &str,
    format: &str,
    pack_name: Option<String>,
    version_id: Option<String>,
    description: Option<String>,
    include_ids: Option<Vec<String>>,
    include_paths: Option<Vec<String>>,
    on_progress: Option<ProgressFn>,
) -> Result<()> {
    let includes = match &include_ids {
        Some(ids) => ExportIncludes::from_ids(ids),
        None => ExportIncludes::default(),
    };
    let path_filter = include_paths.map(|paths| {
        paths
            .into_iter()
            .map(|p| p.replace('\\', "/"))
            .collect::<std::collections::HashSet<_>>()
    });
    match format.trim().to_ascii_lowercase().as_str() {
        "mrpack" | "modrinth" => {
            export_instance_mrpack(
                instance_id,
                export_path,
                pack_name,
                version_id,
                description,
                includes,
                path_filter,
                on_progress,
            )
            .await
        }
        "multimc" | "mmc" => {
            export_instance_multimc(
                instance_id,
                export_path,
                pack_name,
                includes,
                path_filter,
                on_progress,
            )
            .await
        }
        "mcbbs" => {
            export_instance_mcbbs(
                instance_id,
                export_path,
                pack_name,
                version_id,
                description,
                includes,
                path_filter,
                on_progress,
            )
            .await
        }
        other => Err(anyhow!(
            "不支持的导出格式: {other}（支持 mrpack / multimc / mcbbs）"
        )),
    }
}
