use anyhow::Result;
use sqlx::{sqlite::SqliteConnectOptions, SqlitePool};
use std::path::PathBuf;
use std::str::FromStr;

mod accounts;
mod content;
mod instance_settings;
mod instances;
mod launch_defaults;
mod migrations;
mod servers;
mod skins;
mod yggdrasil;

pub use accounts::*;
pub use content::*;
pub use instance_settings::*;
pub use instances::*;
pub use launch_defaults::*;
pub use servers::*;
pub use skins::*;
pub use yggdrasil::*;

pub async fn open_pool(resource_dir: &str) -> Result<SqlitePool> {
    let db_path = PathBuf::from(resource_dir).join("app.db");
    if let Some(parent) = db_path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let options = SqliteConnectOptions::from_str(&format!(
        "sqlite:{}?mode=rwc",
        db_path.to_string_lossy().replace('\\', "/")
    ))?
    .create_if_missing(true);

    let pool = SqlitePool::connect_with(options).await?;
    migrations::migrate(&pool).await?;
    Ok(pool)
}
