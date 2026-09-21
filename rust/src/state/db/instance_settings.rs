use anyhow::Result;
use sqlx::SqlitePool;

use super::instances::get_instance;
use crate::state::models::{Instance, UpdateChannel};

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
