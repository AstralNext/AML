use anyhow::Result;

use crate::launcher::download::ProgressFn;
use crate::state::models::Instance;

use super::curseforge::read_cf_meta_from_zip;
use super::import_common::install_from_cf_meta;

pub(super) async fn install_curse_like(
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
