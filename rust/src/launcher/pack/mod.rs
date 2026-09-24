//! Modpack import/export pipeline (Modrinth / CurseForge / MultiMC / MCBBS).

mod curseforge;
pub use curseforge::{download_cf_file, download_cf_file_to_path};
mod detect;
mod export_common;
mod export_mcbbs;
mod export_mmc;
mod export_mrpack;
mod icon;
mod import_common;
mod import_curseforge;
mod import_mcbbs;
mod import_mmc;
mod import_mrpack;
mod mmc;

pub use detect::detect_pack_file;
pub use export_common::{
    enrich_categories_with_content, summarize_export_content, PackContentCategory,
    PackContentFile, PackExportOptions,
};
pub use export_mcbbs::export_instance_mcbbs;
pub use export_mmc::export_instance_multimc;
pub use export_mrpack::export_instance_mrpack;
pub use icon::try_extract_pack_icon_from_archive;
pub use import_common::{
    create_instance_from_pack_file_resumable, preview_pack_file,
};
pub use import_mmc::create_instance_from_mmc_folder;

use anyhow::{anyhow, Result};
use crate::config::CURSEFORGE_API_KEY_DEFAULT;
use crate::launcher::dirs;
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
    options: PackExportOptions,
) -> Result<()> {
    match format.trim().to_ascii_lowercase().as_str() {
        "mrpack" | "modrinth" => {
            export_instance_mrpack(instance_id, export_path, options).await
        }
        "multimc" | "mmc" => {
            export_instance_multimc(instance_id, export_path, options).await
        }
        "mcbbs" => export_instance_mcbbs(instance_id, export_path, options).await,
        other => Err(anyhow!(
            "不支持的导出格式: {other}（支持 mrpack / multimc / mcbbs）"
        )),
    }
}
