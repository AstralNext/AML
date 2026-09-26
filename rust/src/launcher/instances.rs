use anyhow::{bail, Result};

use crate::state::db;
use crate::state::models::{CreateInstanceRequest, InstallStage, Instance, ModLoader};
use crate::state::{resource_dir, try_state};

use super::dirs;
use super::process::PROCESS_MANAGER;

/// Rename display name and on-disk instance folder together.
pub async fn rename_instance(id: &str, new_name: &str) -> Result<Instance> {
    let Some(name) = db::sanitize_instance_display_name(new_name) else {
        bail!("名称无效，请避免使用空名称或特殊字符 \\ / : * ? \" < > |");
    };

    if PROCESS_MANAGER.get_by_instance(id).is_some() {
        bail!("实例正在运行，请先停止后再重命名");
    }

    let state = try_state()?;
    let resource = resource_dir().await?;
    let current = db::get_instance(&state.pool, id).await?;

    if name == current.name {
        return Ok(current);
    }

    let base = db::sanitize_path(&name);
    let mut path = base.clone();
    if path != current.path {
        let mut n = 1;
        while db::path_taken_by_other(&state.pool, &path, id).await? {
            path = format!("{base}-{n}");
            n += 1;
        }
    }

    if path != current.path {
        let src = dirs::instance_dir(&resource, &current.path);
        let dst = dirs::instance_dir(&resource, &path);
        if src.exists() {
            if dst.exists() {
                bail!("目标文件夹已存在：{path}");
            }
            // Windows is case-insensitive; same-path-different-case needs a temp hop.
            let same_ci = src
                .file_name()
                .and_then(|a| dst.file_name().map(|b| (a, b)))
                .is_some_and(|(a, b)| a.eq_ignore_ascii_case(b));
            if same_ci && src != dst {
                let tmp = dirs::instance_dir(
                    &resource,
                    &format!(".__rename_tmp_{}", uuid::Uuid::new_v4()),
                );
                tokio::fs::rename(&src, &tmp).await?;
                if let Err(e) = tokio::fs::rename(&tmp, &dst).await {
                    let _ = tokio::fs::rename(&tmp, &src).await;
                    return Err(e.into());
                }
            } else {
                tokio::fs::rename(&src, &dst).await?;
            }
        }
    }

    db::update_instance_name_and_path(&state.pool, id, &name, &path).await
}

pub async fn duplicate_instance(source_id: &str) -> Result<Instance> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let source = db::get_instance(&state.pool, source_id).await?;
    let src_dir = dirs::instance_dir(&resource, &source.path);

    let new_name = format!("{} (副本)", source.name);
    let created = db::create_instance(
        &state.pool,
        CreateInstanceRequest {
            name: new_name,
            game_version: source.game_version.clone(),
            loader: ModLoader::parse(&source.loader),
            loader_version: source.loader_version.clone(),
            icon: source.icon.clone(),
        },
    )
    .await?;

    let dst_dir = dirs::ensure_instance_dir(&resource, &created.path).await?;
    if src_dir.exists() {
        dirs::copy_dir_all(&src_dir, &dst_dir).await?;
    }

    let stage = InstallStage::parse(&source.install_stage);
    db::set_install_stage(&state.pool, &created.id, stage).await?;

    if source.java_path.is_some() || source.memory_mb.is_some() || source.extra_jvm_args.is_some() {
        let _ = db::update_instance(
            &state.pool,
            &created.id,
            None,
            Some(source.java_path.clone()),
            source.memory_mb.map(Some),
            source.extra_jvm_args.clone().map(Some),
            None,
        )
        .await?;
    }
    db::update_instance_launch_settings(
        &state.pool,
        &created.id,
        db::LaunchSettingsPatch {
            window_width: Some(source.window_width),
            window_height: Some(source.window_height),
            fullscreen: Some(source.fullscreen),
            environment_vars: Some(source.environment_vars),
            pre_launch_command: Some(source.pre_launch_command),
            wrapper_command: Some(source.wrapper_command),
            post_exit_command: Some(source.post_exit_command),
        },
    )
    .await?;
    let _ = db::set_instance_update_channel(
        &state.pool,
        &created.id,
        crate::state::models::UpdateChannel::parse(&source.update_channel),
    )
    .await?;
    let _ = db::set_instance_groups(&state.pool, &created.id, &source.groups).await?;
    let _ = db::set_instance_modpack_link(
        &state.pool,
        &created.id,
        source.modpack_project_id.as_deref(),
        source.modpack_version_id.as_deref(),
        source.modpack_version_number.as_deref(),
        source.modpack_source.as_deref(),
        source.modpack_title.as_deref(),
    )
    .await?;

    db::get_instance(&state.pool, &created.id).await
}

/// Tri-state field update: `None` keeps the current value, `Some(None)`
/// clears it, `Some(Some(v))` sets it.
pub struct InstanceSettingsUpdate {
    pub name: Option<String>,
    pub java_path: Option<Option<String>>,
    pub memory_mb: Option<Option<i64>>,
    pub extra_jvm_args: Option<Option<String>>,
    pub window_width: Option<Option<i64>>,
    pub window_height: Option<Option<i64>>,
    pub fullscreen: Option<Option<bool>>,
    pub environment_vars: Option<Option<String>>,
    pub pre_launch_command: Option<Option<String>>,
    pub wrapper_command: Option<Option<String>>,
    pub post_exit_command: Option<Option<String>>,
    pub update_channel: Option<String>,
}

/// Validate and persist instance settings (name / java / memory / JVM args /
/// window / hooks / update channel). Returns the refreshed instance.
pub async fn update_instance_settings(
    id: &str,
    update: InstanceSettingsUpdate,
) -> Result<Instance> {
    let InstanceSettingsUpdate {
        name,
        java_path,
        memory_mb,
        extra_jvm_args,
        window_width,
        window_height,
        fullscreen,
        environment_vars,
        pre_launch_command,
        wrapper_command,
        post_exit_command,
        update_channel,
    } = update;

    let state = try_state()?;
    let name = name
        .map(|value| value.trim().chars().take(80).collect::<String>())
        .filter(|value| !value.is_empty());
    if let Some(ref value) = name {
        rename_instance(id, value).await?;
    }
    if let Some(Some(value)) = memory_mb {
        if !(512..=131_072).contains(&value) {
            bail!("内存必须介于 512 MB 和 131072 MB 之间");
        }
    }
    for (label, value) in [("窗口宽度", window_width), ("窗口高度", window_height)] {
        if let Some(Some(value)) = value {
            if !(320..=16_384).contains(&value) {
                bail!("{label}必须介于 320 和 16384 之间");
            }
        }
    }

    db::update_instance(&state.pool, id, None, java_path, memory_mb, extra_jvm_args, None)
        .await?;
    db::update_instance_launch_settings(
        &state.pool,
        id,
        db::LaunchSettingsPatch {
            window_width,
            window_height,
            fullscreen,
            environment_vars,
            pre_launch_command,
            wrapper_command,
            post_exit_command,
        },
    )
    .await?;

    if let Some(channel) = update_channel {
        db::set_instance_update_channel(
            &state.pool,
            id,
            crate::state::models::UpdateChannel::parse(&channel),
        )
        .await?;
    }

    let cur = db::get_instance(&state.pool, id).await?;
    let resource = resource_dir().await?;
    let dir = dirs::instance_dir(&resource, &cur.path);
    if cur.install_stage == InstallStage::NotInstalled.as_str() && dir.exists() {
        let _ = db::set_install_stage(&state.pool, id, InstallStage::Installed).await;
    }

    db::get_instance(&state.pool, id).await
}

/// Remove an instance from the DB and delete its on-disk folder.
pub async fn remove_instance(id: &str) -> Result<()> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::remove_instance(&state.pool, id).await?;
    let dir = dirs::instance_dir(&resource, &instance.path);
    if dir.exists() {
        tokio::fs::remove_dir_all(&dir).await?;
    }
    Ok(())
}
