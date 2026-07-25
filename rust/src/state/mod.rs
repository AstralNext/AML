pub mod db;
pub mod models;
pub mod project_i18n;

use once_cell::sync::OnceCell;
use sqlx::SqlitePool;
use std::sync::Arc;
use tokio::sync::Mutex;

static STATE: OnceCell<Arc<AppState>> = OnceCell::new();

pub struct AppState {
    pub pool: SqlitePool,
    pub resource_dir: Mutex<String>,
}

pub async fn init_state(resource_dir: &str) -> anyhow::Result<Arc<AppState>> {
    if let Some(existing) = STATE.get() {
        *existing.resource_dir.lock().await = resource_dir.to_string();
        return Ok(existing.clone());
    }

    crate::launcher::dirs::ensure_layout(resource_dir).await?;
    let pool = db::open_pool(resource_dir).await?;
    let state = Arc::new(AppState {
        pool,
        resource_dir: Mutex::new(resource_dir.to_string()),
    });
    let _ = STATE.set(state.clone());
    Ok(state)
}

pub fn try_state() -> anyhow::Result<Arc<AppState>> {
    STATE
        .get()
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("AML state not initialized; call init_launcher first"))
}

pub async fn resource_dir() -> anyhow::Result<String> {
    Ok(try_state()?.resource_dir.lock().await.clone())
}
