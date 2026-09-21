use anyhow::Result;
use sqlx::{Row, SqlitePool};

pub(super) async fn migrate(pool: &SqlitePool) -> Result<()> {
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
			pending INTEGER NOT NULL DEFAULT 0,
			download_url TEXT,
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
    ensure_column(pool, "instance_content", "pending", "INTEGER NOT NULL DEFAULT 0").await?;
    ensure_column(pool, "instance_content", "download_url", "TEXT").await?;
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
