//! Mod / mrpack / CurseForge content installation into instances.
//! Resolve compatible version by game/loader, recurse required deps, place by project_type.
//!
//! Submodules:
//! - [`modrinth`]: Modrinth API client (DTOs + fetchers, MCIM fallback)
//! - [`matching`]: version compatibility + update-channel gating
//! - [`files`]: content scanning, metadata sync, enable/disable/remove
//! - [`install`]: single-version install + required-deps recursion + retry
//! - [`mrpack`]: `.mrpack` pack installation + overrides extraction
//! - [`modpack`]: modpack lifecycle (create / unlink / reinstall-or-switch)
//! - [`curseforge`]: CurseForge file + modpack installation
//!
//! The public API is re-exported below so `launcher::content::X` paths stay
//! stable for callers in `api` and `pack`.

mod curseforge;
mod files;
mod install;
mod matching;
mod modpack;
mod modrinth;
mod mrpack;
mod types;

pub use curseforge::{create_instance_from_curseforge_modpack, install_curseforge_file};
pub use files::{
    list_content_files, remove_content_file, set_content_enabled,
    sync_instance_content_metadata, ContentFileEntry,
};
pub use install::{install_modrinth_version, retry_missing_content};
pub use modpack::{
    create_instance_from_modrinth_modpack, reinstall_or_switch_modpack, unlink_modpack,
};
pub use mrpack::install_mrpack;

pub(crate) use mrpack::extract_overrides;
