use anyhow::{anyhow, Result};
use sqlx::{sqlite::SqliteConnectOptions, Row, SqlitePool};
use std::path::PathBuf;
use std::str::FromStr;

use super::models::{
    offline_uuid, Account, CreateInstanceRequest, InstallStage, Instance, LaunchDefaults,
    UpdateChannel, YggdrasilService,
};

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
    migrate(&pool).await?;
    Ok(pool)
}

async fn migrate(pool: &SqlitePool) -> Result<()> {
    sqlx::query(
        r#"
		CREATE TABLE IF NOT EXISTS instances (
			id TEXT PRIMARY KEY NOT NULL,
			path TEXT NOT NULL UNIQUE,
			name TEXT NOT NULL,
			game_version TEXT NOT NULL,
			loader TEXT NOT NULL DEFAULT 'vanilla',
			loader_version TEXT,
			install_stage TEXT NOT NULL DEFAULT 'not_installed',
			java_path TEXT,
			memory_mb INTEGER,
			extra_jvm_args TEXT,
			window_width INTEGER,
			window_height INTEGER,
			fullscreen INTEGER,
			environment_vars TEXT,
			pre_launch_command TEXT,
			wrapper_command TEXT,
			post_exit_command TEXT,
			icon TEXT,
			last_played TEXT,
			created_at TEXT NOT NULL
		);

		CREATE TABLE IF NOT EXISTS accounts (
			id TEXT PRIMARY KEY NOT NULL,
			kind TEXT NOT NULL,
			username TEXT NOT NULL,
			uuid TEXT NOT NULL,
			access_token TEXT,
			refresh_token TEXT,
			expires_at TEXT,
			active INTEGER NOT NULL DEFAULT 0
		);

		CREATE TABLE IF NOT EXISTS yggdrasil_services (
			id TEXT PRIMARY KEY NOT NULL,
			name TEXT NOT NULL,
			api_url TEXT NOT NULL UNIQUE,
			builtin INTEGER NOT NULL DEFAULT 0
		);

		CREATE TABLE IF NOT EXISTS instance_content (
			id TEXT PRIMARY KEY NOT NULL,
			instance_id TEXT NOT NULL,
			relative_path TEXT NOT NULL,
			file_name TEXT NOT NULL,
			project_type TEXT NOT NULL DEFAULT 'mod',
			project_id TEXT,
			version_id TEXT,
			version_number TEXT,
			version_name TEXT,
			project_title TEXT,
			project_icon_url TEXT,
			enabled INTEGER NOT NULL DEFAULT 1,
			sha1 TEXT,
			size_bytes INTEGER,
			added_at TEXT NOT NULL,
			UNIQUE(instance_id, relative_path)
		);

		CREATE TABLE IF NOT EXISTS custom_skins (
			user_uuid TEXT NOT NULL,
			texture_key TEXT NOT NULL,
			name TEXT,
			variant TEXT NOT NULL DEFAULT 'classic',
			cape_id TEXT,
			file_path TEXT NOT NULL,
			display_order INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (user_uuid, texture_key)
		);

		CREATE TABLE IF NOT EXISTS skin_preferences (
			user_uuid TEXT PRIMARY KEY NOT NULL,
			texture_key TEXT NOT NULL,
			variant TEXT NOT NULL DEFAULT 'classic',
			cape_id TEXT
		);

		CREATE TABLE IF NOT EXISTS instance_groups (
			instance_id TEXT NOT NULL,
			group_name TEXT NOT NULL,
			PRIMARY KEY (instance_id, group_name),
			FOREIGN KEY (instance_id) REFERENCES instances(id) ON DELETE CASCADE
		);

		CREATE TABLE IF NOT EXISTS launch_defaults (
			id INTEGER PRIMARY KEY CHECK (id = 1),
			memory_mb INTEGER NOT NULL DEFAULT 4096,
			extra_jvm_args TEXT,
			window_width INTEGER NOT NULL DEFAULT 854,
			window_height INTEGER NOT NULL DEFAULT 480,
			fullscreen INTEGER NOT NULL DEFAULT 0,
			environment_vars TEXT,
			pre_launch_command TEXT,
			wrapper_command TEXT,
			post_exit_command TEXT
		);
		"#,
    )
    .execute(pool)
    .await?;

    ensure_column(pool, "instance_content", "author", "TEXT").await?;
    ensure_column(pool, "instance_content", "author_avatar_url", "TEXT").await?;
    ensure_column(pool, "instance_content", "author_id", "TEXT").await?;
    ensure_column(pool, "instance_content", "author_type", "TEXT").await?;
    ensure_column(pool, "instance_content", "update_version_id", "TEXT").await?;
    ensure_column(pool, "accounts", "client_token", "TEXT").await?;
    ensure_column(pool, "accounts", "auth_server_id", "TEXT").await?;
    ensure_column(pool, "instances", "window_width", "INTEGER").await?;
    ensure_column(pool, "instances", "window_height", "INTEGER").await?;
    ensure_column(pool, "instances", "fullscreen", "INTEGER").await?;
    ensure_column(pool, "instances", "environment_vars", "TEXT").await?;
    ensure_column(pool, "instances", "pre_launch_command", "TEXT").await?;
    ensure_column(pool, "instances", "wrapper_command", "TEXT").await?;
    ensure_column(pool, "instances", "post_exit_command", "TEXT").await?;
    ensure_column(pool, "instances", "update_channel", "TEXT").await?;
    ensure_column(pool, "instances", "modpack_project_id", "TEXT").await?;
    ensure_column(pool, "instances", "modpack_version_id", "TEXT").await?;
    ensure_column(pool, "instances", "modpack_version_number", "TEXT").await?;
    ensure_column(pool, "instances", "modpack_source", "TEXT").await?;
    ensure_column(pool, "instances", "modpack_title", "TEXT").await?;
    ensure_column(
        pool,
        "instances",
        "auto_backup_worlds",
        "INTEGER NOT NULL DEFAULT 0",
    )
    .await?;
    ensure_column(pool, "launch_defaults", "game_language", "TEXT").await?;
    // Prefer Simplified Chinese for first-time installs of this Chinese launcher.
    sqlx::query(
        "UPDATE launch_defaults SET game_language = 'zh_cn' WHERE id = 1 AND (game_language IS NULL OR game_language = '')",
    )
    .execute(pool)
    .await?;
    sqlx::query(
        r#"INSERT OR IGNORE INTO yggdrasil_services (id, name, api_url, builtin)
		VALUES ('littleskin', 'LittleSkin', 'https://littleskin.cn/api/yggdrasil', 1)"#,
    )
    .execute(pool)
    .await?;
    sqlx::query(
        r#"INSERT OR IGNORE INTO launch_defaults (id, memory_mb, window_width, window_height, fullscreen, game_language)
		VALUES (1, 4096, 854, 480, 0, 'zh_cn')"#,
    )
    .execute(pool)
    .await?;
    sqlx::query(
        "UPDATE instances SET update_channel = 'release' WHERE update_channel IS NULL OR update_channel = ''",
    )
    .execute(pool)
    .await?;
    // Per-server last-join times (for home "Jump back in"), keyed by host+port.
    sqlx::query(
        r#"
		CREATE TABLE IF NOT EXISTS server_join_log (
			instance_id TEXT NOT NULL,
			host TEXT NOT NULL,
			port INTEGER NOT NULL,
			join_time_ms INTEGER NOT NULL,
			PRIMARY KEY (instance_id, host, port)
		)"#,
    )
    .execute(pool)
    .await?;

    // Discover title/summary + detail-body translation caches.
    crate::state::project_i18n::migrate_tables(pool).await?;
    Ok(())
}

async fn ensure_column(pool: &SqlitePool, table: &str, column: &str, ty: &str) -> Result<()> {
    let rows = sqlx::query(&format!("PRAGMA table_info({table})"))
        .fetch_all(pool)
        .await?;
    let exists = rows.iter().any(|r| {
        r.try_get::<String, _>("name")
            .map(|n| n == column)
            .unwrap_or(false)
    });
    if !exists {
        sqlx::query(&format!("ALTER TABLE {table} ADD COLUMN {column} {ty}"))
            .execute(pool)
            .await?;
    }
    Ok(())
}

/// Folder-safe name: keep Unicode, strip Windows-forbidden / control chars.
pub fn sanitize_path(name: &str) -> String {
    let mut s: String = name
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    s = s.trim().trim_matches('.').chars().take(80).collect();
    while s.contains("__") {
        s = s.replace("__", "_");
    }
    let upper = s.to_ascii_uppercase();
    const RESERVED: &[&str] = &[
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6",
        "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7",
        "LPT8", "LPT9",
    ];
    if RESERVED.iter().any(|r| upper == *r) {
        s = format!("{s}_instance");
    }
    if s.is_empty() {
        "instance".into()
    } else {
        s
    }
}

/// Display name: same forbidden-char rules as folders (path-safe).
pub fn sanitize_instance_display_name(name: &str) -> Option<String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return None;
    }
    let meaningful: String = trimmed
        .chars()
        .filter(|c| {
            !matches!(*c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') && !c.is_control()
        })
        .collect();
    if meaningful.trim().trim_matches('.').is_empty() {
        return None;
    }
    Some(sanitize_path(trimmed))
}

pub async fn create_instance(pool: &SqlitePool, req: CreateInstanceRequest) -> Result<Instance> {
    let id = format!("local:{}", uuid::Uuid::new_v4());
    let base = sanitize_path(&req.name);
    let mut path = base.clone();
    let mut n = 1;
    loop {
        let exists: Option<(String,)> = sqlx::query_as("SELECT id FROM instances WHERE path = ?")
            .bind(&path)
            .fetch_optional(pool)
            .await?;
        if exists.is_none() {
            break;
        }
        path = format!("{base}-{n}");
        n += 1;
    }

    let created_at = super::models::now_rfc3339();
    let instance = Instance {
        id: id.clone(),
        path: path.clone(),
        name: req.name,
        game_version: req.game_version,
        loader: req.loader.as_str().to_string(),
        loader_version: req.loader_version,
        install_stage: InstallStage::NotInstalled.as_str().to_string(),
        java_path: None,
        memory_mb: None,
        extra_jvm_args: None,
        window_width: None,
        window_height: None,
        fullscreen: None,
        environment_vars: None,
        pre_launch_command: None,
        wrapper_command: None,
        post_exit_command: None,
        update_channel: UpdateChannel::Release.as_str().to_string(),
        auto_backup_worlds: false,
        groups: vec![],
        modpack_project_id: None,
        modpack_version_id: None,
        modpack_version_number: None,
        modpack_source: None,
        modpack_title: None,
        icon: req.icon,
        last_played: None,
        created_at: created_at.clone(),
    };

    sqlx::query(
        r#"INSERT INTO instances
		(id, path, name, game_version, loader, loader_version, install_stage, icon, update_channel, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"#,
    )
    .bind(&instance.id)
    .bind(&instance.path)
    .bind(&instance.name)
    .bind(&instance.game_version)
    .bind(&instance.loader)
    .bind(&instance.loader_version)
    .bind(&instance.install_stage)
    .bind(&instance.icon)
    .bind(&instance.update_channel)
    .bind(&instance.created_at)
    .execute(pool)
    .await?;

    Ok(instance)
}

const INSTANCE_SELECT: &str = r#"SELECT id, path, name, game_version, loader, loader_version, install_stage,
			java_path, memory_mb, extra_jvm_args, window_width, window_height, fullscreen,
			environment_vars, pre_launch_command, wrapper_command, post_exit_command,
			COALESCE(update_channel, 'release') as update_channel,
			COALESCE(auto_backup_worlds, 0) as auto_backup_worlds,
			modpack_project_id, modpack_version_id, modpack_version_number,
			modpack_source, modpack_title,
			icon, last_played, created_at
			FROM instances"#;

pub async fn list_instances(pool: &SqlitePool) -> Result<Vec<Instance>> {
    let rows = sqlx::query_as::<_, InstanceRow>(&format!(
        "{INSTANCE_SELECT} ORDER BY COALESCE(last_played, created_at) DESC"
    ))
    .fetch_all(pool)
    .await?;
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let mut instance = row.into_instance();
        instance.groups = list_instance_groups(pool, &instance.id).await?;
        out.push(instance);
    }
    Ok(out)
}

pub async fn get_instance(pool: &SqlitePool, id: &str) -> Result<Instance> {
    let row = sqlx::query_as::<_, InstanceRow>(&format!("{INSTANCE_SELECT} WHERE id = ?"))
        .bind(id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| anyhow!("instance not found: {id}"))?;
    let mut instance = row.into_instance();
    instance.groups = list_instance_groups(pool, &instance.id).await?;
    Ok(instance)
}

pub async fn set_install_stage(pool: &SqlitePool, id: &str, stage: InstallStage) -> Result<()> {
    sqlx::query("UPDATE instances SET install_stage = ? WHERE id = ?")
        .bind(stage.as_str())
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn set_last_played(pool: &SqlitePool, id: &str) -> Result<()> {
    sqlx::query("UPDATE instances SET last_played = ? WHERE id = ?")
        .bind(super::models::now_rfc3339())
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

/// Record a multiplayer join for home recent-servers / world list sorting.
pub async fn record_server_join(
    pool: &SqlitePool,
    instance_id: &str,
    address: &str,
) -> Result<()> {
    let Ok((host, port)) =
        crate::launcher::server_address::parse_server_address(address)
    else {
        return Ok(());
    };
    let now = chrono::Utc::now().timestamp_millis();
    sqlx::query(
        r#"
		INSERT INTO server_join_log (instance_id, host, port, join_time_ms)
		VALUES (?, ?, ?, ?)
		ON CONFLICT (instance_id, host, port) DO UPDATE SET
			join_time_ms = excluded.join_time_ms
		"#,
    )
    .bind(instance_id)
    .bind(&host)
    .bind(port as i64)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

/// `(host, port) → join_time_ms` for an instance.
pub async fn get_server_joins(
    pool: &SqlitePool,
    instance_id: &str,
) -> Result<std::collections::HashMap<(String, u16), i64>> {
    let rows = sqlx::query(
        "SELECT host, port, join_time_ms FROM server_join_log WHERE instance_id = ?",
    )
    .bind(instance_id)
    .fetch_all(pool)
    .await?;

    let mut out = std::collections::HashMap::new();
    for row in rows {
        let host: String = row.try_get("host")?;
        let port: i64 = row.try_get("port")?;
        let ms: i64 = row.try_get("join_time_ms")?;
        if port >= 0 && port <= u16::MAX as i64 {
            out.insert((host, port as u16), ms);
        }
    }
    Ok(out)
}

pub async fn update_instance(
    pool: &SqlitePool,
    id: &str,
    name: Option<String>,
    java_path: Option<Option<String>>,
    memory_mb: Option<Option<i64>>,
    extra_jvm_args: Option<Option<String>>,
    loader_version: Option<Option<String>>,
) -> Result<Instance> {
    let mut current = get_instance(pool, id).await?;
    if let Some(n) = name {
        current.name = n;
    }
    if let Some(j) = java_path {
        current.java_path = j;
    }
    if let Some(m) = memory_mb {
        current.memory_mb = m;
    }
    if let Some(a) = extra_jvm_args {
        current.extra_jvm_args = a;
    }
    if let Some(lv) = loader_version {
        current.loader_version = lv;
    }

    sqlx::query(
        r#"UPDATE instances SET name = ?, java_path = ?, memory_mb = ?,
			extra_jvm_args = ?, loader_version = ? WHERE id = ?"#,
    )
    .bind(&current.name)
    .bind(&current.java_path)
    .bind(&current.memory_mb)
    .bind(&current.extra_jvm_args)
    .bind(&current.loader_version)
    .bind(id)
    .execute(pool)
    .await?;

    Ok(current)
}

pub async fn update_instance_name_and_path(
    pool: &SqlitePool,
    id: &str,
    name: &str,
    path: &str,
) -> Result<Instance> {
    sqlx::query(r#"UPDATE instances SET name = ?, path = ? WHERE id = ?"#)
        .bind(name)
        .bind(path)
        .bind(id)
        .execute(pool)
        .await?;
    get_instance(pool, id).await
}

pub async fn path_taken_by_other(
    pool: &SqlitePool,
    path: &str,
    exclude_id: &str,
) -> Result<bool> {
    let row: Option<(String,)> =
        sqlx::query_as("SELECT id FROM instances WHERE path = ? AND id != ?")
            .bind(path)
            .bind(exclude_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.is_some())
}

#[allow(clippy::too_many_arguments)]
pub async fn update_instance_launch_settings(
    pool: &SqlitePool,
    id: &str,
    window_width: Option<Option<i64>>,
    window_height: Option<Option<i64>>,
    fullscreen: Option<Option<bool>>,
    environment_vars: Option<Option<String>>,
    pre_launch_command: Option<Option<String>>,
    wrapper_command: Option<Option<String>>,
    post_exit_command: Option<Option<String>>,
) -> Result<Instance> {
    let mut current = get_instance(pool, id).await?;
    if let Some(value) = window_width {
        current.window_width = value;
    }
    if let Some(value) = window_height {
        current.window_height = value;
    }
    if let Some(value) = fullscreen {
        current.fullscreen = value;
    }
    if let Some(value) = environment_vars {
        current.environment_vars = value;
    }
    if let Some(value) = pre_launch_command {
        current.pre_launch_command = value;
    }
    if let Some(value) = wrapper_command {
        current.wrapper_command = value;
    }
    if let Some(value) = post_exit_command {
        current.post_exit_command = value;
    }

    sqlx::query(
        r#"UPDATE instances SET window_width = ?, window_height = ?, fullscreen = ?,
			environment_vars = ?, pre_launch_command = ?, wrapper_command = ?,
			post_exit_command = ? WHERE id = ?"#,
    )
    .bind(current.window_width)
    .bind(current.window_height)
    .bind(current.fullscreen.map(i64::from))
    .bind(&current.environment_vars)
    .bind(&current.pre_launch_command)
    .bind(&current.wrapper_command)
    .bind(&current.post_exit_command)
    .bind(id)
    .execute(pool)
    .await?;

    Ok(current)
}

pub async fn set_instance_auto_backup_worlds(
    pool: &SqlitePool,
    id: &str,
    enabled: bool,
) -> Result<Instance> {
    sqlx::query("UPDATE instances SET auto_backup_worlds = ? WHERE id = ?")
        .bind(i64::from(enabled))
        .bind(id)
        .execute(pool)
        .await?;
    get_instance(pool, id).await
}

pub async fn set_instance_update_channel(
    pool: &SqlitePool,
    id: &str,
    channel: UpdateChannel,
) -> Result<Instance> {
    sqlx::query("UPDATE instances SET update_channel = ? WHERE id = ?")
        .bind(channel.as_str())
        .bind(id)
        .execute(pool)
        .await?;
    get_instance(pool, id).await
}

pub async fn list_instance_groups(pool: &SqlitePool, instance_id: &str) -> Result<Vec<String>> {
    let rows: Vec<(String,)> = sqlx::query_as(
        "SELECT group_name FROM instance_groups WHERE instance_id = ? ORDER BY group_name",
    )
    .bind(instance_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(name,)| name).collect())
}

pub async fn list_all_groups(pool: &SqlitePool) -> Result<Vec<String>> {
    let rows: Vec<(String,)> =
        sqlx::query_as("SELECT DISTINCT group_name FROM instance_groups ORDER BY group_name")
            .fetch_all(pool)
            .await?;
    Ok(rows.into_iter().map(|(name,)| name).collect())
}

pub async fn set_instance_groups(
    pool: &SqlitePool,
    instance_id: &str,
    groups: &[String],
) -> Result<Instance> {
    let _ = get_instance(pool, instance_id).await?;
    sqlx::query("DELETE FROM instance_groups WHERE instance_id = ?")
        .bind(instance_id)
        .execute(pool)
        .await?;
    for raw in groups {
        let name = raw.trim().chars().take(32).collect::<String>();
        if name.is_empty() {
            continue;
        }
        sqlx::query(
            "INSERT OR IGNORE INTO instance_groups (instance_id, group_name) VALUES (?, ?)",
        )
        .bind(instance_id)
        .bind(&name)
        .execute(pool)
        .await?;
    }
    get_instance(pool, instance_id).await
}

pub async fn set_instance_modpack_link(
    pool: &SqlitePool,
    id: &str,
    project_id: Option<&str>,
    version_id: Option<&str>,
    version_number: Option<&str>,
    source: Option<&str>,
    title: Option<&str>,
) -> Result<Instance> {
    sqlx::query(
        r#"UPDATE instances SET
			modpack_project_id = ?,
			modpack_version_id = ?,
			modpack_version_number = ?,
			modpack_source = ?,
			modpack_title = ?
			WHERE id = ?"#,
    )
    .bind(project_id)
    .bind(version_id)
    .bind(version_number)
    .bind(source)
    .bind(title)
    .bind(id)
    .execute(pool)
    .await?;
    get_instance(pool, id).await
}

pub async fn unlink_instance_modpack(pool: &SqlitePool, id: &str) -> Result<Instance> {
    set_instance_modpack_link(pool, id, None, None, None, None, None).await
}

pub async fn get_launch_defaults(pool: &SqlitePool) -> Result<LaunchDefaults> {
    let row = sqlx::query_as::<_, LaunchDefaultsRow>(
        r#"SELECT memory_mb, extra_jvm_args, window_width, window_height, fullscreen,
			environment_vars, pre_launch_command, wrapper_command, post_exit_command,
			game_language
			FROM launch_defaults WHERE id = 1"#,
    )
    .fetch_optional(pool)
    .await?;
    Ok(row
        .map(LaunchDefaultsRow::into_defaults)
        .unwrap_or_default())
}

pub async fn set_launch_defaults(
    pool: &SqlitePool,
    defaults: &LaunchDefaults,
) -> Result<LaunchDefaults> {
    if !(512..=131_072).contains(&defaults.memory_mb) {
        return Err(anyhow!("内存必须介于 512 MB 和 131072 MB 之间"));
    }
    if !(320..=16_384).contains(&defaults.window_width)
        || !(320..=16_384).contains(&defaults.window_height)
    {
        return Err(anyhow!("窗口宽高必须介于 320 和 16384 之间"));
    }
    sqlx::query(
        r#"INSERT INTO launch_defaults
		(id, memory_mb, extra_jvm_args, window_width, window_height, fullscreen,
			environment_vars, pre_launch_command, wrapper_command, post_exit_command,
			game_language)
		VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			memory_mb = excluded.memory_mb,
			extra_jvm_args = excluded.extra_jvm_args,
			window_width = excluded.window_width,
			window_height = excluded.window_height,
			fullscreen = excluded.fullscreen,
			environment_vars = excluded.environment_vars,
			pre_launch_command = excluded.pre_launch_command,
			wrapper_command = excluded.wrapper_command,
			post_exit_command = excluded.post_exit_command,
			game_language = excluded.game_language"#,
    )
    .bind(defaults.memory_mb)
    .bind(&defaults.extra_jvm_args)
    .bind(defaults.window_width)
    .bind(defaults.window_height)
    .bind(i64::from(defaults.fullscreen))
    .bind(&defaults.environment_vars)
    .bind(&defaults.pre_launch_command)
    .bind(&defaults.wrapper_command)
    .bind(&defaults.post_exit_command)
    .bind(&defaults.game_language)
    .execute(pool)
    .await?;
    get_launch_defaults(pool).await
}

pub async fn set_instance_icon(pool: &SqlitePool, id: &str, icon: Option<String>) -> Result<()> {
    sqlx::query("UPDATE instances SET icon = ? WHERE id = ?")
        .bind(&icon)
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn remove_instance(pool: &SqlitePool, id: &str) -> Result<Instance> {
    let instance = get_instance(pool, id).await?;
    sqlx::query("DELETE FROM instance_groups WHERE instance_id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM instance_content WHERE instance_id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM server_join_log WHERE instance_id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    sqlx::query("DELETE FROM instances WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(instance)
}

pub async fn list_accounts(pool: &SqlitePool) -> Result<Vec<Account>> {
    let rows = sqlx::query_as::<_, AccountRow>(
        r#"SELECT id, kind, username, uuid, access_token, refresh_token, client_token,
			auth_server_id, expires_at, active
			FROM accounts ORDER BY rowid ASC"#,
    )
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(AccountRow::into_account).collect())
}

pub async fn get_active_account(pool: &SqlitePool) -> Result<Option<Account>> {
    let row = sqlx::query_as::<_, AccountRow>(
        r#"SELECT id, kind, username, uuid, access_token, refresh_token, client_token,
			auth_server_id, expires_at, active
			FROM accounts WHERE active = 1 LIMIT 1"#,
    )
    .fetch_optional(pool)
    .await?;
    Ok(row.map(AccountRow::into_account))
}

pub async fn upsert_offline_account(pool: &SqlitePool, username: &str) -> Result<Account> {
    let uuid = offline_uuid(username);
    let id = format!("offline:{uuid}");

    sqlx::query("UPDATE accounts SET active = 0")
        .execute(pool)
        .await?;

    sqlx::query(
        r#"INSERT INTO accounts (id, kind, username, uuid, access_token, active)
		VALUES (?, 'offline', ?, ?, '0', 1)
		ON CONFLICT(id) DO UPDATE SET username = excluded.username, active = 1"#,
    )
    .bind(&id)
    .bind(username)
    .bind(&uuid)
    .execute(pool)
    .await?;

    Ok(Account {
        id,
        kind: "offline".into(),
        username: username.into(),
        uuid,
        access_token: Some("0".into()),
        refresh_token: None,
        client_token: None,
        auth_server_id: None,
        expires_at: None,
        active: true,
    })
}

pub async fn upsert_msa_account(
    pool: &SqlitePool,
    username: &str,
    uuid: &str,
    access_token: &str,
    refresh_token: Option<&str>,
    expires_at: Option<&str>,
) -> Result<Account> {
    let id = format!("msa:{uuid}");
    sqlx::query("UPDATE accounts SET active = 0")
        .execute(pool)
        .await?;
    sqlx::query(
		r#"INSERT INTO accounts (id, kind, username, uuid, access_token, refresh_token, expires_at, active)
		VALUES (?, 'msa', ?, ?, ?, ?, ?, 1)
		ON CONFLICT(id) DO UPDATE SET
			username = excluded.username,
			access_token = excluded.access_token,
			refresh_token = excluded.refresh_token,
			expires_at = excluded.expires_at,
			active = 1"#,
	)
	.bind(&id)
	.bind(username)
	.bind(uuid)
	.bind(access_token)
	.bind(refresh_token)
	.bind(expires_at)
	.execute(pool)
	.await?;

    Ok(Account {
        id,
        kind: "msa".into(),
        username: username.into(),
        uuid: uuid.into(),
        access_token: Some(access_token.into()),
        refresh_token: refresh_token.map(|s| s.to_string()),
        client_token: None,
        auth_server_id: None,
        expires_at: expires_at.map(|s| s.to_string()),
        active: true,
    })
}

pub async fn list_yggdrasil_services(pool: &SqlitePool) -> Result<Vec<YggdrasilService>> {
    let rows = sqlx::query_as::<_, YggdrasilServiceRow>(
        "SELECT id, name, api_url, builtin FROM yggdrasil_services ORDER BY builtin DESC, name",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(YggdrasilServiceRow::into_service)
        .collect())
}

pub async fn get_yggdrasil_service(pool: &SqlitePool, id: &str) -> Result<YggdrasilService> {
    let row = sqlx::query_as::<_, YggdrasilServiceRow>(
        "SELECT id, name, api_url, builtin FROM yggdrasil_services WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?
    .ok_or_else(|| anyhow!("Yggdrasil 服务不存在: {id}"))?;
    Ok(row.into_service())
}

pub async fn upsert_yggdrasil_service(
    pool: &SqlitePool,
    id: &str,
    name: &str,
    api_url: &str,
) -> Result<YggdrasilService> {
    sqlx::query(
        r#"INSERT INTO yggdrasil_services (id, name, api_url, builtin)
		VALUES (?, ?, ?, 0)
		ON CONFLICT(id) DO UPDATE SET name = excluded.name, api_url = excluded.api_url"#,
    )
    .bind(id)
    .bind(name)
    .bind(api_url)
    .execute(pool)
    .await?;
    get_yggdrasil_service(pool, id).await
}

pub async fn remove_yggdrasil_service(pool: &SqlitePool, id: &str) -> Result<()> {
    let in_use: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM accounts WHERE auth_server_id = ?")
        .bind(id)
        .fetch_one(pool)
        .await?;
    if in_use > 0 {
        return Err(anyhow!("该服务仍有 {in_use} 个账号，无法删除"));
    }
    let result = sqlx::query("DELETE FROM yggdrasil_services WHERE id = ? AND builtin = 0")
        .bind(id)
        .execute(pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(anyhow!("内置服务不能删除"));
    }
    Ok(())
}

pub async fn upsert_yggdrasil_account(
    pool: &SqlitePool,
    service_id: &str,
    username: &str,
    uuid: &str,
    access_token: &str,
    client_token: &str,
    expires_at: &str,
) -> Result<Account> {
    let id = format!("yggdrasil:{service_id}:{uuid}");
    sqlx::query("UPDATE accounts SET active = 0")
        .execute(pool)
        .await?;
    sqlx::query(
        r#"INSERT INTO accounts (
			id, kind, username, uuid, access_token, client_token,
			auth_server_id, expires_at, active
		) VALUES (?, 'yggdrasil', ?, ?, ?, ?, ?, ?, 1)
		ON CONFLICT(id) DO UPDATE SET
			username = excluded.username,
			access_token = excluded.access_token,
			client_token = excluded.client_token,
			auth_server_id = excluded.auth_server_id,
			expires_at = excluded.expires_at,
			active = 1"#,
    )
    .bind(&id)
    .bind(username)
    .bind(uuid)
    .bind(access_token)
    .bind(client_token)
    .bind(service_id)
    .bind(expires_at)
    .execute(pool)
    .await?;
    Ok(Account {
        id,
        kind: "yggdrasil".into(),
        username: username.into(),
        uuid: uuid.into(),
        access_token: Some(access_token.into()),
        refresh_token: None,
        client_token: Some(client_token.into()),
        auth_server_id: Some(service_id.into()),
        expires_at: Some(expires_at.into()),
        active: true,
    })
}

pub async fn update_yggdrasil_account_token(
    pool: &SqlitePool,
    id: &str,
    access_token: &str,
    client_token: &str,
    expires_at: &str,
) -> Result<()> {
    sqlx::query(
        "UPDATE accounts SET access_token = ?, client_token = ?, expires_at = ? WHERE id = ?",
    )
    .bind(access_token)
    .bind(client_token)
    .bind(expires_at)
    .bind(id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn set_active_account(pool: &SqlitePool, id: &str) -> Result<()> {
    sqlx::query("UPDATE accounts SET active = 0")
        .execute(pool)
        .await?;
    let result = sqlx::query("UPDATE accounts SET active = 1 WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(anyhow!("account not found: {id}"));
    }
    Ok(())
}

pub async fn remove_account(pool: &SqlitePool, id: &str) -> Result<()> {
    sqlx::query("DELETE FROM accounts WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

#[derive(sqlx::FromRow)]
struct InstanceRow {
    id: String,
    path: String,
    name: String,
    game_version: String,
    loader: String,
    loader_version: Option<String>,
    install_stage: String,
    java_path: Option<String>,
    memory_mb: Option<i64>,
    extra_jvm_args: Option<String>,
    window_width: Option<i64>,
    window_height: Option<i64>,
    fullscreen: Option<i64>,
    environment_vars: Option<String>,
    pre_launch_command: Option<String>,
    wrapper_command: Option<String>,
    post_exit_command: Option<String>,
    update_channel: String,
    auto_backup_worlds: i64,
    modpack_project_id: Option<String>,
    modpack_version_id: Option<String>,
    modpack_version_number: Option<String>,
    modpack_source: Option<String>,
    modpack_title: Option<String>,
    icon: Option<String>,
    last_played: Option<String>,
    created_at: String,
}

impl InstanceRow {
    fn into_instance(self) -> Instance {
        Instance {
            id: self.id,
            path: self.path,
            name: self.name,
            game_version: self.game_version,
            loader: self.loader,
            loader_version: self.loader_version,
            install_stage: self.install_stage,
            java_path: self.java_path,
            memory_mb: self.memory_mb,
            extra_jvm_args: self.extra_jvm_args,
            window_width: self.window_width,
            window_height: self.window_height,
            fullscreen: self.fullscreen.map(|value| value != 0),
            environment_vars: self.environment_vars,
            pre_launch_command: self.pre_launch_command,
            wrapper_command: self.wrapper_command,
            post_exit_command: self.post_exit_command,
            update_channel: if self.update_channel.trim().is_empty() {
                UpdateChannel::Release.as_str().to_string()
            } else {
                self.update_channel
            },
            auto_backup_worlds: self.auto_backup_worlds != 0,
            groups: vec![],
            modpack_project_id: self.modpack_project_id,
            modpack_version_id: self.modpack_version_id,
            modpack_version_number: self.modpack_version_number,
            modpack_source: self.modpack_source,
            modpack_title: self.modpack_title,
            icon: self.icon,
            last_played: self.last_played,
            created_at: self.created_at,
        }
    }
}

#[derive(sqlx::FromRow)]
struct LaunchDefaultsRow {
    memory_mb: i64,
    extra_jvm_args: Option<String>,
    window_width: i64,
    window_height: i64,
    fullscreen: i64,
    environment_vars: Option<String>,
    pre_launch_command: Option<String>,
    wrapper_command: Option<String>,
    post_exit_command: Option<String>,
    game_language: Option<String>,
}

impl LaunchDefaultsRow {
    fn into_defaults(self) -> LaunchDefaults {
        LaunchDefaults {
            memory_mb: self.memory_mb,
            extra_jvm_args: self.extra_jvm_args,
            window_width: self.window_width,
            window_height: self.window_height,
            fullscreen: self.fullscreen != 0,
            environment_vars: self.environment_vars,
            pre_launch_command: self.pre_launch_command,
            wrapper_command: self.wrapper_command,
            post_exit_command: self.post_exit_command,
            game_language: self
                .game_language
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        }
    }
}

#[derive(sqlx::FromRow)]
struct AccountRow {
    id: String,
    kind: String,
    username: String,
    uuid: String,
    access_token: Option<String>,
    refresh_token: Option<String>,
    client_token: Option<String>,
    auth_server_id: Option<String>,
    expires_at: Option<String>,
    active: i64,
}

#[derive(sqlx::FromRow)]
struct YggdrasilServiceRow {
    id: String,
    name: String,
    api_url: String,
    builtin: i64,
}

impl YggdrasilServiceRow {
    fn into_service(self) -> YggdrasilService {
        YggdrasilService {
            id: self.id,
            name: self.name,
            api_url: self.api_url,
            builtin: self.builtin != 0,
        }
    }
}

impl AccountRow {
    fn into_account(self) -> Account {
        Account {
            id: self.id,
            kind: self.kind,
            username: self.username,
            uuid: self.uuid,
            access_token: self.access_token,
            refresh_token: self.refresh_token,
            client_token: self.client_token,
            auth_server_id: self.auth_server_id,
            expires_at: self.expires_at,
            active: self.active != 0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ContentEntry {
    pub id: String,
    pub instance_id: String,
    pub relative_path: String,
    pub file_name: String,
    pub project_type: String,
    pub project_id: Option<String>,
    pub version_id: Option<String>,
    pub version_number: Option<String>,
    pub version_name: Option<String>,
    pub project_title: Option<String>,
    pub project_icon_url: Option<String>,
    pub author: Option<String>,
    pub author_avatar_url: Option<String>,
    pub author_id: Option<String>,
    pub author_type: Option<String>,
    pub update_version_id: Option<String>,
    pub enabled: bool,
    pub sha1: Option<String>,
    pub size_bytes: Option<i64>,
    pub added_at: String,
}

#[derive(sqlx::FromRow)]
struct ContentRow {
    id: String,
    instance_id: String,
    relative_path: String,
    file_name: String,
    project_type: String,
    project_id: Option<String>,
    version_id: Option<String>,
    version_number: Option<String>,
    version_name: Option<String>,
    project_title: Option<String>,
    project_icon_url: Option<String>,
    author: Option<String>,
    author_avatar_url: Option<String>,
    author_id: Option<String>,
    author_type: Option<String>,
    update_version_id: Option<String>,
    enabled: i64,
    sha1: Option<String>,
    size_bytes: Option<i64>,
    added_at: String,
}

impl ContentRow {
    fn into_entry(self) -> ContentEntry {
        ContentEntry {
            id: self.id,
            instance_id: self.instance_id,
            relative_path: self.relative_path,
            file_name: self.file_name,
            project_type: self.project_type,
            project_id: self.project_id,
            version_id: self.version_id,
            version_number: self.version_number,
            version_name: self.version_name,
            project_title: self.project_title,
            project_icon_url: self.project_icon_url,
            author: self.author,
            author_avatar_url: self.author_avatar_url,
            author_id: self.author_id,
            author_type: self.author_type,
            update_version_id: self.update_version_id,
            enabled: self.enabled != 0,
            sha1: self.sha1,
            size_bytes: self.size_bytes,
            added_at: self.added_at,
        }
    }
}

pub async fn upsert_content_entry(pool: &SqlitePool, entry: &ContentEntry) -> Result<()> {
    sqlx::query(
        r#"
		INSERT INTO instance_content (
			id, instance_id, relative_path, file_name, project_type,
			project_id, version_id, version_number, version_name,
			project_title, project_icon_url, author, author_avatar_url,
			author_id, author_type, update_version_id, enabled, sha1, size_bytes, added_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(instance_id, relative_path) DO UPDATE SET
			file_name = excluded.file_name,
			project_type = excluded.project_type,
			project_id = COALESCE(excluded.project_id, instance_content.project_id),
			version_id = COALESCE(excluded.version_id, instance_content.version_id),
			version_number = COALESCE(excluded.version_number, instance_content.version_number),
			version_name = COALESCE(excluded.version_name, instance_content.version_name),
			project_title = COALESCE(excluded.project_title, instance_content.project_title),
			project_icon_url = COALESCE(excluded.project_icon_url, instance_content.project_icon_url),
			author = COALESCE(excluded.author, instance_content.author),
			author_avatar_url = COALESCE(excluded.author_avatar_url, instance_content.author_avatar_url),
			author_id = COALESCE(excluded.author_id, instance_content.author_id),
			author_type = COALESCE(excluded.author_type, instance_content.author_type),
			update_version_id = excluded.update_version_id,
			enabled = excluded.enabled,
			sha1 = COALESCE(excluded.sha1, instance_content.sha1),
			size_bytes = COALESCE(excluded.size_bytes, instance_content.size_bytes)
		"#,
    )
    .bind(&entry.id)
    .bind(&entry.instance_id)
    .bind(&entry.relative_path)
    .bind(&entry.file_name)
    .bind(&entry.project_type)
    .bind(&entry.project_id)
    .bind(&entry.version_id)
    .bind(&entry.version_number)
    .bind(&entry.version_name)
    .bind(&entry.project_title)
    .bind(&entry.project_icon_url)
    .bind(&entry.author)
    .bind(&entry.author_avatar_url)
    .bind(&entry.author_id)
    .bind(&entry.author_type)
    .bind(&entry.update_version_id)
    .bind(if entry.enabled { 1 } else { 0 })
    .bind(&entry.sha1)
    .bind(entry.size_bytes)
    .bind(&entry.added_at)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn list_content_for_instance(
    pool: &SqlitePool,
    instance_id: &str,
) -> Result<Vec<ContentEntry>> {
    let rows = sqlx::query_as::<_, ContentRow>(
        r#"SELECT * FROM instance_content WHERE instance_id = ? ORDER BY file_name COLLATE NOCASE"#,
    )
    .bind(instance_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(ContentRow::into_entry).collect())
}

pub async fn list_content_by_project(
    pool: &SqlitePool,
    instance_id: &str,
    project_id: &str,
) -> Result<Vec<ContentEntry>> {
    let rows = sqlx::query_as::<_, ContentRow>(
        r#"SELECT * FROM instance_content
		WHERE instance_id = ? AND project_id = ?
		ORDER BY file_name COLLATE NOCASE"#,
    )
    .bind(instance_id)
    .bind(project_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(ContentRow::into_entry).collect())
}

pub async fn update_content_path_and_enabled(
    pool: &SqlitePool,
    instance_id: &str,
    old_relative_path: &str,
    new_relative_path: &str,
    file_name: &str,
    enabled: bool,
) -> Result<()> {
    sqlx::query(
        r#"UPDATE instance_content
		SET relative_path = ?, file_name = ?, enabled = ?
		WHERE instance_id = ? AND relative_path = ?"#,
    )
    .bind(new_relative_path)
    .bind(file_name)
    .bind(if enabled { 1 } else { 0 })
    .bind(instance_id)
    .bind(old_relative_path)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn remove_content_entry(
    pool: &SqlitePool,
    instance_id: &str,
    relative_path: &str,
) -> Result<()> {
    sqlx::query(r#"DELETE FROM instance_content WHERE instance_id = ? AND relative_path = ?"#)
        .bind(instance_id)
        .bind(relative_path)
        .execute(pool)
        .await?;
    Ok(())
}

#[derive(Debug, Clone)]
pub struct CustomSkinRow {
    pub texture_key: String,
    pub name: Option<String>,
    pub variant: String,
    pub cape_id: Option<String>,
    pub file_path: String,
}

#[derive(Debug, Clone)]
pub struct SkinPreference {
    pub texture_key: String,
    pub variant: String,
    pub cape_id: Option<String>,
}

pub async fn list_custom_skins(pool: &SqlitePool, user_uuid: &str) -> Result<Vec<CustomSkinRow>> {
    let rows = sqlx::query(
        r#"SELECT texture_key, name, variant, cape_id, file_path
		FROM custom_skins WHERE user_uuid = ?
		ORDER BY display_order ASC, texture_key ASC"#,
    )
    .bind(user_uuid)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| CustomSkinRow {
            texture_key: r.get("texture_key"),
            name: r.get("name"),
            variant: r.get("variant"),
            cape_id: r.get("cape_id"),
            file_path: r.get("file_path"),
        })
        .collect())
}

pub async fn get_custom_skin(
    pool: &SqlitePool,
    user_uuid: &str,
    texture_key: &str,
) -> Result<Option<CustomSkinRow>> {
    let row = sqlx::query(
        r#"SELECT texture_key, name, variant, cape_id, file_path
		FROM custom_skins WHERE user_uuid = ? AND texture_key = ?"#,
    )
    .bind(user_uuid)
    .bind(texture_key)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|r| CustomSkinRow {
        texture_key: r.get("texture_key"),
        name: r.get("name"),
        variant: r.get("variant"),
        cape_id: r.get("cape_id"),
        file_path: r.get("file_path"),
    }))
}

pub async fn upsert_custom_skin(
    pool: &SqlitePool,
    user_uuid: &str,
    texture_key: &str,
    name: Option<&str>,
    variant: &str,
    cape_id: Option<&str>,
    file_path: &str,
) -> Result<()> {
    sqlx::query(
		r#"INSERT INTO custom_skins (user_uuid, texture_key, name, variant, cape_id, file_path, display_order)
		VALUES (?, ?, ?, ?, ?, ?, 0)
		ON CONFLICT(user_uuid, texture_key) DO UPDATE SET
			name = excluded.name,
			variant = excluded.variant,
			cape_id = excluded.cape_id,
			file_path = excluded.file_path"#,
	)
	.bind(user_uuid)
	.bind(texture_key)
	.bind(name)
	.bind(variant)
	.bind(cape_id)
	.bind(file_path)
	.execute(pool)
	.await?;
    Ok(())
}

pub async fn delete_custom_skin(
    pool: &SqlitePool,
    user_uuid: &str,
    texture_key: &str,
) -> Result<()> {
    sqlx::query(r#"DELETE FROM custom_skins WHERE user_uuid = ? AND texture_key = ?"#)
        .bind(user_uuid)
        .bind(texture_key)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn get_skin_preference(
    pool: &SqlitePool,
    user_uuid: &str,
) -> Result<Option<SkinPreference>> {
    let row = sqlx::query(
        r#"SELECT texture_key, variant, cape_id FROM skin_preferences WHERE user_uuid = ?"#,
    )
    .bind(user_uuid)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|r| SkinPreference {
        texture_key: r.get("texture_key"),
        variant: r.get("variant"),
        cape_id: r.get("cape_id"),
    }))
}

pub async fn set_skin_preference(
    pool: &SqlitePool,
    user_uuid: &str,
    texture_key: &str,
    variant: &str,
    cape_id: Option<&str>,
) -> Result<()> {
    sqlx::query(
        r#"INSERT INTO skin_preferences (user_uuid, texture_key, variant, cape_id)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(user_uuid) DO UPDATE SET
			texture_key = excluded.texture_key,
			variant = excluded.variant,
			cape_id = excluded.cape_id"#,
    )
    .bind(user_uuid)
    .bind(texture_key)
    .bind(variant)
    .bind(cape_id)
    .execute(pool)
    .await?;
    Ok(())
}
