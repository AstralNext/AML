use anyhow::{anyhow, Result};
use sqlx::SqlitePool;

use crate::state::models::LaunchDefaults;

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
