use anyhow::{anyhow, Result};
use sqlx::SqlitePool;

use super::instance_settings::list_instance_groups;
use crate::state::models::{CreateInstanceRequest, InstallStage, Instance, UpdateChannel};

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

    let created_at = crate::state::models::now_rfc3339();
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
        .bind(crate::state::models::now_rfc3339())
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
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
