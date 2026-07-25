use flutter_rust_bridge::DartFnFuture;
use std::sync::Arc;

use crate::launcher;
use crate::state;
use crate::state::db;
use crate::state::models::{CreateInstanceRequest, ModLoader};

/// Initialize launcher DB and directory layout under resource_dir.
pub async fn init_launcher(resource_dir: String) -> Result<(), String> {
    state::init_state(&resource_dir)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[derive(Clone, Debug)]
pub struct InstanceDto {
    pub id: String,
    pub path: String,
    pub name: String,
    pub game_version: String,
    pub loader: String,
    pub loader_version: Option<String>,
    pub install_stage: String,
    pub java_path: Option<String>,
    pub memory_mb: Option<i64>,
    pub extra_jvm_args: Option<String>,
    pub window_width: Option<i64>,
    pub window_height: Option<i64>,
    pub fullscreen: Option<bool>,
    pub environment_vars: Option<String>,
    pub pre_launch_command: Option<String>,
    pub wrapper_command: Option<String>,
    pub post_exit_command: Option<String>,
    pub update_channel: String,
    pub auto_backup_worlds: bool,
    pub groups: Vec<String>,
    pub modpack_project_id: Option<String>,
    pub modpack_version_id: Option<String>,
    pub modpack_version_number: Option<String>,
    pub modpack_source: Option<String>,
    pub modpack_title: Option<String>,
    pub icon: Option<String>,
    pub last_played: Option<String>,
    pub created_at: String,
}

impl From<crate::state::models::Instance> for InstanceDto {
    fn from(i: crate::state::models::Instance) -> Self {
        Self {
            id: i.id,
            path: i.path,
            name: i.name,
            game_version: i.game_version,
            loader: i.loader,
            loader_version: i.loader_version,
            install_stage: i.install_stage,
            java_path: i.java_path,
            memory_mb: i.memory_mb,
            extra_jvm_args: i.extra_jvm_args,
            window_width: i.window_width,
            window_height: i.window_height,
            fullscreen: i.fullscreen,
            environment_vars: i.environment_vars,
            pre_launch_command: i.pre_launch_command,
            wrapper_command: i.wrapper_command,
            post_exit_command: i.post_exit_command,
            update_channel: i.update_channel,
            auto_backup_worlds: i.auto_backup_worlds,
            groups: i.groups,
            modpack_project_id: i.modpack_project_id,
            modpack_version_id: i.modpack_version_id,
            modpack_version_number: i.modpack_version_number,
            modpack_source: i.modpack_source,
            modpack_title: i.modpack_title,
            icon: i.icon,
            last_played: i.last_played,
            created_at: i.created_at,
        }
    }
}

#[derive(Clone, Debug)]
pub struct LaunchDefaultsDto {
    pub memory_mb: i64,
    pub extra_jvm_args: Option<String>,
    pub window_width: i64,
    pub window_height: i64,
    pub fullscreen: bool,
    pub environment_vars: Option<String>,
    pub pre_launch_command: Option<String>,
    pub wrapper_command: Option<String>,
    pub post_exit_command: Option<String>,
    pub game_language: Option<String>,
}

impl From<crate::state::models::LaunchDefaults> for LaunchDefaultsDto {
    fn from(value: crate::state::models::LaunchDefaults) -> Self {
        Self {
            memory_mb: value.memory_mb,
            extra_jvm_args: value.extra_jvm_args,
            window_width: value.window_width,
            window_height: value.window_height,
            fullscreen: value.fullscreen,
            environment_vars: value.environment_vars,
            pre_launch_command: value.pre_launch_command,
            wrapper_command: value.wrapper_command,
            post_exit_command: value.post_exit_command,
            game_language: value.game_language,
        }
    }
}

pub async fn list_instances() -> Result<Vec<InstanceDto>, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::list_instances(&state.pool)
        .await
        .map(|v| v.into_iter().map(InstanceDto::from).collect())
        .map_err(|e| e.to_string())
}

pub async fn get_instance(id: String) -> Result<InstanceDto, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::get_instance(&state.pool, &id)
        .await
        .map(InstanceDto::from)
        .map_err(|e| e.to_string())
}

pub async fn create_instance(
    name: String,
    game_version: String,
    loader: String,
    loader_version: Option<String>,
    icon: Option<String>,
) -> Result<InstanceDto, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let resource = state::resource_dir().await.map_err(|e| e.to_string())?;
    let resolved_icon = if let Some(ref src) = icon {
        launcher::icons::resolve_icon_source(&resource, src)
            .await
            .map_err(|e| format!("{e:#}"))?
    } else {
        None
    };
    let req = CreateInstanceRequest {
        name,
        game_version,
        loader: ModLoader::parse(&loader),
        loader_version,
        icon: resolved_icon,
    };
    let instance = db::create_instance(&state.pool, req)
        .await
        .map_err(|e| e.to_string())?;
    launcher::dirs::ensure_instance_dir(&resource, &instance.path)
        .await
        .map_err(|e| e.to_string())?;
    Ok(InstanceDto::from(instance))
}

pub async fn update_instance(
    id: String,
    name: Option<String>,
    java_path: Option<String>,
    clear_java_path: bool,
    memory_mb: Option<i64>,
    clear_memory_mb: bool,
    extra_jvm_args: Option<String>,
    clear_extra_jvm_args: bool,
    window_width: Option<i64>,
    window_height: Option<i64>,
    fullscreen: Option<bool>,
    clear_window_settings: bool,
    environment_vars: Option<String>,
    clear_environment_vars: bool,
    pre_launch_command: Option<String>,
    wrapper_command: Option<String>,
    post_exit_command: Option<String>,
    clear_hooks: bool,
    update_channel: Option<String>,
) -> Result<InstanceDto, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let name = name
        .map(|value| value.trim().chars().take(80).collect::<String>())
        .filter(|value| !value.is_empty());
    if let Some(ref value) = name {
        launcher::instances::rename_instance(&id, value)
            .await
            .map_err(|e| format!("{e:#}"))?;
    }
    if let Some(value) = memory_mb {
        if !(512..=131_072).contains(&value) {
            return Err("内存必须介于 512 MB 和 131072 MB 之间".into());
        }
    }
    for (label, value) in [("窗口宽度", window_width), ("窗口高度", window_height)] {
        if let Some(value) = value {
            if !(320..=16_384).contains(&value) {
                return Err(format!("{label}必须介于 320 和 16384 之间"));
            }
        }
    }
    let java = if clear_java_path {
        Some(None)
    } else {
        java_path.map(Some)
    };
    let memory = if clear_memory_mb {
        Some(None)
    } else {
        memory_mb.map(Some)
    };
    let args = if clear_extra_jvm_args {
        Some(None)
    } else {
        extra_jvm_args.map(Some)
    };
    // Name+folder already handled by rename_instance above.
    db::update_instance(&state.pool, &id, None, java, memory, args, None)
        .await
        .map_err(|e| e.to_string())?;

    let width = if clear_window_settings {
        Some(None)
    } else {
        window_width.map(Some)
    };
    let height = if clear_window_settings {
        Some(None)
    } else {
        window_height.map(Some)
    };
    let fullscreen = if clear_window_settings {
        Some(None)
    } else {
        fullscreen.map(Some)
    };
    let environment = if clear_environment_vars {
        Some(None)
    } else {
        environment_vars.map(Some)
    };
    let pre_launch = if clear_hooks {
        Some(None)
    } else {
        pre_launch_command.map(Some)
    };
    let wrapper = if clear_hooks {
        Some(None)
    } else {
        wrapper_command.map(Some)
    };
    let post_exit = if clear_hooks {
        Some(None)
    } else {
        post_exit_command.map(Some)
    };

    db::update_instance_launch_settings(
        &state.pool,
        &id,
        width,
        height,
        fullscreen,
        environment,
        pre_launch,
        wrapper,
        post_exit,
    )
    .await
    .map_err(|e| e.to_string())?;

    if let Some(channel) = update_channel {
        db::set_instance_update_channel(
            &state.pool,
            &id,
            crate::state::models::UpdateChannel::parse(&channel),
        )
        .await
        .map_err(|e| e.to_string())?;
    }

    db::get_instance(&state.pool, &id)
        .await
        .map(InstanceDto::from)
        .map_err(|e| e.to_string())
}

pub async fn set_instance_groups(id: String, groups: Vec<String>) -> Result<InstanceDto, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::set_instance_groups(&state.pool, &id, &groups)
        .await
        .map(InstanceDto::from)
        .map_err(|e| e.to_string())
}

pub async fn list_all_instance_groups() -> Result<Vec<String>, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::list_all_groups(&state.pool)
        .await
        .map_err(|e| e.to_string())
}

pub async fn get_launch_defaults() -> Result<LaunchDefaultsDto, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::get_launch_defaults(&state.pool)
        .await
        .map(LaunchDefaultsDto::from)
        .map_err(|e| e.to_string())
}

pub async fn set_launch_defaults(
    memory_mb: i64,
    extra_jvm_args: Option<String>,
    window_width: i64,
    window_height: i64,
    fullscreen: bool,
    environment_vars: Option<String>,
    pre_launch_command: Option<String>,
    wrapper_command: Option<String>,
    post_exit_command: Option<String>,
    game_language: Option<String>,
) -> Result<LaunchDefaultsDto, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let lang = game_language
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let defaults = crate::state::models::LaunchDefaults {
        memory_mb,
        extra_jvm_args,
        window_width,
        window_height,
        fullscreen,
        environment_vars,
        pre_launch_command,
        wrapper_command,
        post_exit_command,
        game_language: lang,
    };
    db::set_launch_defaults(&state.pool, &defaults)
        .await
        .map(LaunchDefaultsDto::from)
        .map_err(|e| e.to_string())
}

pub async fn unlink_modpack(id: String) -> Result<InstanceDto, String> {
    launcher::content::unlink_modpack(&id)
        .await
        .map(InstanceDto::from)
        .map_err(|e| format!("{e:#}"))
}

pub async fn reinstall_modpack(
    id: String,
    version_id: Option<String>,
    java_path: Option<String>,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<InstanceDto, String> {
    use std::sync::Arc;
    let cb: launcher::download::ProgressFn = Arc::new(move |p, m| {
        let fut = on_progress(p, m);
        tokio::spawn(async move {
            fut.await;
        });
    });
    launcher::content::reinstall_or_switch_modpack(&id, version_id.as_deref(), java_path, Some(cb))
        .await
        .map(InstanceDto::from)
        .map_err(|e| format!("{e:#}"))
}

/// Set or clear instance icon (local path, URL, or `None` to remove).
pub async fn edit_instance_icon(
    id: String,
    icon_path: Option<String>,
) -> Result<InstanceDto, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let resource = state::resource_dir().await.map_err(|e| e.to_string())?;
    let resolved = if let Some(ref src) = icon_path {
        launcher::icons::resolve_icon_source(&resource, src)
            .await
            .map_err(|e| format!("{e:#}"))?
    } else {
        None
    };
    launcher::icons::set_instance_icon(&state.pool, &id, resolved)
        .await
        .map_err(|e| e.to_string())?;
    db::get_instance(&state.pool, &id)
        .await
        .map(InstanceDto::from)
        .map_err(|e| e.to_string())
}

pub async fn duplicate_instance(id: String) -> Result<InstanceDto, String> {
    let instance = launcher::instances::duplicate_instance(&id)
        .await
        .map(InstanceDto::from)
        .map_err(|e| format!("{e:#}"))?;
    Ok(instance)
}

pub async fn remove_instance(id: String) -> Result<(), String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let resource = state::resource_dir().await.map_err(|e| e.to_string())?;
    let instance = db::remove_instance(&state.pool, &id)
        .await
        .map_err(|e| e.to_string())?;
    let dir = launcher::dirs::instance_dir(&resource, &instance.path);
    if dir.exists() {
        tokio::fs::remove_dir_all(&dir)
            .await
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub async fn install_instance(
    id: String,
    java_path: Option<String>,
    force: bool,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<InstanceDto, String> {
    let cb: launcher::download::ProgressFn = Arc::new(move |p, m| {
        let fut = on_progress(p, m);
        tokio::spawn(async move {
            fut.await;
        });
    });
    launcher::install::install_instance(&id, java_path, force, Some(cb))
        .await
        .map(InstanceDto::from)
        .map_err(|e| {
            eprintln!("[AML] install_instance({id}): {e:#}");
            format!("{e:#}")
        })
}

pub async fn launch_instance(
    id: String,
    java_path: String,
    quick_play_singleplayer: Option<String>,
    quick_play_multiplayer: Option<String>,
) -> Result<ProcessDto, String> {
    launcher::auth::refresh_active_account_if_needed()
        .await
        .map_err(|e| e.to_string())?;
    launcher::install::launch_instance(
        &id,
        java_path,
        quick_play_singleplayer,
        quick_play_multiplayer,
    )
        .await
        .map(|m| ProcessDto {
            uuid: m.uuid,
            instance_id: m.instance_id,
        })
        .map_err(|e| e.to_string())
}

/// Java major version required by this instance's Minecraft metadata
/// (`javaVersion.majorVersion`, default 8).
pub async fn get_required_java_version(id: String) -> Result<u32, String> {
    launcher::install::required_java_major_for_instance(&id)
        .await
        .map_err(|e| e.to_string())
}

pub async fn kill_instance(id: String) -> Result<(), String> {
    launcher::process::PROCESS_MANAGER
        .kill_instance(&id)
        .await
        .map_err(|e| e.to_string())
}

pub async fn list_running_processes() -> Result<Vec<ProcessDto>, String> {
    Ok(launcher::process::PROCESS_MANAGER
        .list()
        .into_iter()
        .map(|m| ProcessDto {
            uuid: m.uuid,
            instance_id: m.instance_id,
        })
        .collect())
}

/// Subscribe to Minecraft process lifecycle events (`launched` / `finished`).
/// Call once at app start; events are pushed without Dart-side polling.
pub fn watch_process_events(
    on_event: impl Fn(ProcessEventDto) -> DartFnFuture<()> + Send + Sync + 'static,
) {
    let on_event = Arc::new(on_event);
    launcher::process::subscribe_process_events(Arc::new(move |ev| {
        let dto = ProcessEventDto {
            instance_id: ev.instance_id,
            uuid: ev.uuid,
            event: ev.event,
            message: ev.message,
        };
        let fut = on_event(dto);
        tokio::spawn(async move {
            fut.await;
        });
    }));
}

#[derive(Clone, Debug)]
pub struct ProcessEventDto {
    pub instance_id: String,
    pub uuid: String,
    /// `"launched"` | `"finished"`
    pub event: String,
    pub message: String,
}

/// Subscribe to live stdout/stderr log lines (no Dart polling).
pub fn watch_live_log_events(
    on_event: impl Fn(LiveLogEventDto) -> DartFnFuture<()> + Send + Sync + 'static,
) {
    let on_event = Arc::new(on_event);
    launcher::process::subscribe_live_log_events(Arc::new(move |ev| {
        let dto = LiveLogEventDto {
            instance_id: ev.instance_id,
            line: ev.line,
            cleared: ev.cleared,
        };
        let fut = on_event(dto);
        tokio::spawn(async move {
            fut.await;
        });
    }));
}

#[derive(Clone, Debug)]
pub struct LiveLogEventDto {
    pub instance_id: String,
    /// One line or a newline-delimited batch.
    pub line: String,
    /// When true, the live buffer was cleared (e.g. new launch).
    pub cleared: bool,
}

pub async fn get_live_logs(instance_id: String) -> Result<Vec<String>, String> {
    Ok(launcher::process::PROCESS_MANAGER.get_live_logs(&instance_id))
}

pub async fn clear_live_logs(instance_id: String) -> Result<(), String> {
    launcher::process::PROCESS_MANAGER.clear_live_logs(&instance_id);
    Ok(())
}

pub async fn get_launcher_log(instance_id: String) -> Result<String, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let resource = state::resource_dir().await.map_err(|e| e.to_string())?;
    let instance = db::get_instance(&state.pool, &instance_id)
        .await
        .map_err(|e| e.to_string())?;
    let path = launcher::dirs::instance_dir(&resource, &instance.path)
        .join("logs")
        .join("launcher_log.txt");
    if !path.exists() {
        return Ok(String::new());
    }
    tokio::fs::read_to_string(&path)
        .await
        .map_err(|e| e.to_string())
}

#[derive(Clone, Debug)]
pub struct ModFileDto {
    pub name: String,
    pub relative_path: String,
    pub enabled: bool,
    pub size_bytes: u64,
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
    pub has_update: bool,
}

pub async fn list_instance_mods(instance_id: String) -> Result<Vec<ModFileDto>, String> {
    // Fast path: join local files with cached DB metadata only.
    // Network sync / hashing happens via `sync_instance_content_metadata`.
    let state = state::try_state().map_err(|e| e.to_string())?;
    let resource = state::resource_dir().await.map_err(|e| e.to_string())?;
    let instance = db::get_instance(&state.pool, &instance_id)
        .await
        .map_err(|e| e.to_string())?;
    let root = launcher::dirs::instance_dir(&resource, &instance.path);
    let db_entries = db::list_content_for_instance(&state.pool, &instance_id)
        .await
        .map_err(|e| e.to_string())?;
    let mut by_path: std::collections::HashMap<String, db::ContentEntry> = db_entries
        .into_iter()
        .map(|e| (e.relative_path.replace('\\', "/"), e))
        .collect();

    let mut out = Vec::new();
    for folder in ["mods", "resourcepacks", "shaderpacks", "datapacks"] {
        let dir = root.join(folder);
        if !dir.exists() {
            continue;
        }
        let mut entries = tokio::fs::read_dir(&dir).await.map_err(|e| e.to_string())?;
        while let Some(entry) = entries.next_entry().await.map_err(|e| e.to_string())? {
            let name = entry.file_name().to_string_lossy().to_string();
            let lower = name.to_lowercase();
            let ok = lower.ends_with(".jar")
                || lower.ends_with(".jar.disabled")
                || lower.ends_with(".zip")
                || lower.ends_with(".zip.disabled");
            if !ok {
                continue;
            }
            let meta = entry.metadata().await.map_err(|e| e.to_string())?;
            if !meta.is_file() {
                continue;
            }
            let relative = format!("{folder}/{name}").replace('\\', "/");
            let enabled = !lower.ends_with(".disabled");
            let db_hit = by_path.remove(&relative).or_else(|| {
                let alt = if enabled {
                    format!("{relative}.disabled")
                } else {
                    relative.trim_end_matches(".disabled").to_string()
                };
                by_path.remove(&alt)
            });
            out.push(ModFileDto {
                name: name.clone(),
                relative_path: relative,
                enabled,
                size_bytes: meta.len(),
                project_type: db_hit
                    .as_ref()
                    .map(|e| e.project_type.clone())
                    .unwrap_or_else(|| match folder {
                        "mods" => "mod".into(),
                        "resourcepacks" => "resourcepack".into(),
                        "shaderpacks" => "shader".into(),
                        "datapacks" => "datapack".into(),
                        _ => "mod".into(),
                    }),
                project_id: db_hit.as_ref().and_then(|e| e.project_id.clone()),
                version_id: db_hit.as_ref().and_then(|e| e.version_id.clone()),
                version_number: db_hit.as_ref().and_then(|e| e.version_number.clone()),
                version_name: db_hit.as_ref().and_then(|e| e.version_name.clone()),
                project_title: db_hit.as_ref().and_then(|e| e.project_title.clone()),
                project_icon_url: db_hit.as_ref().and_then(|e| e.project_icon_url.clone()),
                author: db_hit.as_ref().and_then(|e| e.author.clone()),
                author_avatar_url: db_hit.as_ref().and_then(|e| e.author_avatar_url.clone()),
                author_id: db_hit.as_ref().and_then(|e| e.author_id.clone()),
                author_type: db_hit.as_ref().and_then(|e| e.author_type.clone()),
                update_version_id: db_hit.as_ref().and_then(|e| e.update_version_id.clone()),
                has_update: db_hit
                    .as_ref()
                    .and_then(|e| e.update_version_id.as_ref())
                    .is_some(),
            });
        }
    }
    out.sort_by(|a, b| {
        a.project_title
            .as_deref()
            .unwrap_or(&a.name)
            .to_lowercase()
            .cmp(&b.project_title.as_deref().unwrap_or(&b.name).to_lowercase())
    });
    Ok(out)
}

/// Background sync: hash unmatched files, resolve Modrinth metadata/authors.
/// Set `checkUpdates` to also query Modrinth for newer versions (slower).
pub async fn sync_instance_content_metadata(
    instance_id: String,
    check_updates: bool,
) -> Result<(), String> {
    launcher::content::sync_instance_content_metadata(&instance_id, check_updates)
        .await
        .map_err(|e| format!("{e:#}"))
}

pub async fn set_mod_enabled(
    instance_id: String,
    relative_path: String,
    enabled: bool,
) -> Result<(), String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let resource = state::resource_dir().await.map_err(|e| e.to_string())?;
    let instance = db::get_instance(&state.pool, &instance_id)
        .await
        .map_err(|e| e.to_string())?;
    let root = launcher::dirs::instance_dir(&resource, &instance.path);
    let current = root.join(&relative_path);
    if !current.is_file() {
        return Err(format!("文件不存在: {relative_path}"));
    }
    let file_name = current
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let target = if enabled {
        if let Some(stripped) = file_name.strip_suffix(".disabled") {
            current.with_file_name(stripped)
        } else {
            current.clone()
        }
    } else if file_name.to_lowercase().ends_with(".jar") {
        current.with_file_name(format!("{file_name}.disabled"))
    } else {
        current.clone()
    };

    if target != current {
        tokio::fs::rename(&current, &target)
            .await
            .map_err(|e| e.to_string())?;
        let new_name = target
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or(file_name);
        let new_rel = {
            let parent = std::path::Path::new(&relative_path)
                .parent()
                .map(|p| p.to_string_lossy().replace('\\', "/"))
                .unwrap_or_default();
            if parent.is_empty() {
                new_name.clone()
            } else {
                format!("{parent}/{new_name}")
            }
        };
        let _ = db::update_content_path_and_enabled(
            &state.pool,
            &instance_id,
            &relative_path,
            &new_rel,
            &new_name,
            enabled,
        )
        .await;
    }
    Ok(())
}

pub async fn remove_instance_mod(instance_id: String, relative_path: String) -> Result<(), String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let resource = state::resource_dir().await.map_err(|e| e.to_string())?;
    let instance = db::get_instance(&state.pool, &instance_id)
        .await
        .map_err(|e| e.to_string())?;
    let root = launcher::dirs::instance_dir(&resource, &instance.path);
    let path = root.join(&relative_path);
    if !path.is_file() {
        return Err(format!("文件不存在: {relative_path}"));
    }
    // Only allow deleting under known content folders.
    let normalized = relative_path.replace('\\', "/");
    let allowed = normalized.starts_with("mods/")
        || normalized.starts_with("resourcepacks/")
        || normalized.starts_with("shaderpacks/")
        || normalized.starts_with("datapacks/");
    if !allowed {
        return Err("只能删除实例内容目录下的文件".into());
    }
    tokio::fs::remove_file(&path)
        .await
        .map_err(|e| e.to_string())?;
    let _ = db::remove_content_entry(&state.pool, &instance_id, &normalized).await;
    Ok(())
}

pub async fn open_instance_folder(instance_id: String) -> Result<String, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let resource = state::resource_dir().await.map_err(|e| e.to_string())?;
    let instance = db::get_instance(&state.pool, &instance_id)
        .await
        .map_err(|e| e.to_string())?;
    let dir = launcher::dirs::instance_dir(&resource, &instance.path);
    Ok(dir.to_string_lossy().to_string())
}

#[derive(Clone, Debug)]
pub struct WorldDto {
    pub kind: String,
    pub name: String,
    pub folder: String,
    pub game_mode: String,
    pub hardcore: bool,
    pub last_played_ms: Option<i64>,
    pub icon_path: Option<String>,
    pub icon_data_url: Option<String>,
    pub server_address: Option<String>,
    pub server_index: Option<i32>,
    pub backup_count: u32,
}

impl From<launcher::worlds::WorldInfo> for WorldDto {
    fn from(w: launcher::worlds::WorldInfo) -> Self {
        Self {
            kind: w.kind,
            name: w.name,
            folder: w.folder,
            game_mode: w.game_mode,
            hardcore: w.hardcore,
            last_played_ms: w.last_played_ms,
            icon_path: w.icon_path,
            icon_data_url: w.icon_data_url,
            server_address: w.server_address,
            server_index: w.server_index,
            backup_count: w.backup_count,
        }
    }
}

pub async fn list_instance_worlds(instance_id: String) -> Result<Vec<WorldDto>, String> {
    launcher::worlds::list_instance_worlds(&instance_id)
        .await
        .map(|v| v.into_iter().map(WorldDto::from).collect())
        .map_err(|e| e.to_string())
}

pub async fn delete_instance_world(instance_id: String, folder: String) -> Result<(), String> {
    launcher::worlds::delete_instance_world(&instance_id, &folder)
        .await
        .map_err(|e| e.to_string())
}

pub async fn add_instance_server(
    instance_id: String,
    name: String,
    address: String,
) -> Result<i32, String> {
    launcher::worlds::add_instance_server(&instance_id, &name, &address)
        .await
        .map_err(|e| format!("{e:#}"))
}

pub async fn remove_instance_server(instance_id: String, index: i32) -> Result<(), String> {
    launcher::worlds::remove_instance_server(&instance_id, index)
        .await
        .map_err(|e| format!("{e:#}"))
}

pub async fn edit_instance_server(
    instance_id: String,
    index: i32,
    name: String,
    address: String,
) -> Result<(), String> {
    launcher::worlds::edit_instance_server(&instance_id, index, &name, &address)
        .await
        .map_err(|e| format!("{e:#}"))
}

#[derive(Clone, Debug)]
pub struct ServerStatusDto {
    /// Raw MOTD JSON (string or chat component). UI parses colors / formatting.
    pub description_json: Option<String>,
    pub players_online: Option<i32>,
    pub players_max: Option<i32>,
    pub player_sample: Vec<String>,
    pub version_name: Option<String>,
    pub version_protocol: Option<i32>,
    pub legacy: bool,
    /// `data:image/png;base64,...` when present.
    pub favicon: Option<String>,
    pub ping_ms: Option<i64>,
}

/// Server List Ping. Prefer modern protocol; pass `legacy: true` as fallback.
pub async fn get_server_status(
    address: String,
    protocol_version: Option<i32>,
    legacy: Option<bool>,
) -> Result<ServerStatusDto, String> {
    let legacy_flag = legacy.unwrap_or(false);
    let status = launcher::server_ping::ping_server(
        &address,
        protocol_version,
        legacy_flag,
    )
    .await
    .map_err(|e| {
        eprintln!("[AML ping] API error address={address:?} legacy={legacy_flag}: {e:#}");
        format!("{e:#}")
    })?;

    let players = status.players;
    let version = status.version;
    let dto = ServerStatusDto {
        description_json: status.description.map(|v| v.get().to_owned()),
        players_online: players.as_ref().map(|p| p.online),
        players_max: players.as_ref().map(|p| p.max),
        player_sample: players
            .map(|p| p.sample.into_iter().map(|s| s.name).collect())
            .unwrap_or_default(),
        version_name: version.as_ref().map(|v| v.name.clone()),
        version_protocol: version.as_ref().map(|v| v.protocol),
        legacy: version.map(|v| v.legacy).unwrap_or(false),
        favicon: status.favicon,
        ping_ms: status.ping,
    };
    eprintln!(
        "[AML ping] DTO address={address:?} motd_len={:?} favicon_len={:?} players={:?}/{:?} ping_ms={:?}",
        dto.description_json.as_ref().map(|s| s.len()),
        dto.favicon.as_ref().map(|s| s.len()),
        dto.players_online,
        dto.players_max,
        dto.ping_ms,
    );
    Ok(dto)
}

#[derive(Clone, Debug)]
pub struct WorldBackupDto {
    pub id: String,
    pub world_folder: String,
    pub file_name: String,
    pub created_at: String,
    pub size_bytes: u64,
    pub path: String,
    pub auto: bool,
    /// `full` | `incremental`
    pub kind: String,
    /// `store` | `fast` | `balanced` | `max`
    pub compression: String,
    pub parent_id: Option<String>,
    pub base_full_id: Option<String>,
    pub icon_path: Option<String>,
    pub file_count: u32,
}

impl From<launcher::world_backup::WorldBackupInfo> for WorldBackupDto {
    fn from(v: launcher::world_backup::WorldBackupInfo) -> Self {
        Self {
            id: v.id,
            world_folder: v.world_folder,
            file_name: v.file_name,
            created_at: v.created_at,
            size_bytes: v.size_bytes,
            path: v.path,
            auto: v.auto,
            kind: v.kind,
            compression: v.compression,
            parent_id: v.parent_id,
            base_full_id: v.base_full_id,
            icon_path: v.icon_path,
            file_count: v.file_count,
        }
    }
}

pub async fn backup_instance_world(
    instance_id: String,
    folder: String,
    kind: String,
    compression: String,
) -> Result<WorldBackupDto, String> {
    let kind = launcher::world_backup::BackupKind::parse(&kind).map_err(|e| e.to_string())?;
    let compression =
        launcher::world_backup::CompressionPreset::parse(&compression).map_err(|e| e.to_string())?;
    launcher::world_backup::backup_world(&instance_id, &folder, false, kind, compression)
        .await
        .map(WorldBackupDto::from)
        .map_err(|e| format!("{e:#}"))
}

pub async fn list_world_backups(
    instance_id: String,
    folder: String,
) -> Result<Vec<WorldBackupDto>, String> {
    launcher::world_backup::list_world_backups(&instance_id, &folder)
        .await
        .map(|v| v.into_iter().map(WorldBackupDto::from).collect())
        .map_err(|e| format!("{e:#}"))
}

pub async fn restore_world_backup(
    instance_id: String,
    backup_path: String,
) -> Result<(), String> {
    launcher::world_backup::restore_world_backup(&instance_id, &backup_path)
        .await
        .map_err(|e| format!("{e:#}"))
}

pub async fn delete_world_backup(
    instance_id: String,
    backup_path: String,
) -> Result<(), String> {
    launcher::world_backup::delete_world_backup(&instance_id, &backup_path)
        .await
        .map_err(|e| format!("{e:#}"))
}

pub async fn set_instance_auto_backup_worlds(
    id: String,
    enabled: bool,
) -> Result<InstanceDto, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::set_instance_auto_backup_worlds(&state.pool, &id, enabled)
        .await
        .map(InstanceDto::from)
        .map_err(|e| format!("{e:#}"))
}

#[derive(Clone, Debug)]
pub struct WorldMapChunkDto {
    pub chunk_x: i32,
    pub chunk_z: i32,
    pub rgba: Vec<u8>,
}

#[derive(Clone, Debug)]
pub struct WorldMapStreamEventDto {
    pub min_chunk_x: i32,
    pub min_chunk_z: i32,
    pub max_chunk_x: i32,
    pub max_chunk_z: i32,
    pub chunks_done: u32,
    pub chunks_total: u32,
    pub chunk: Option<WorldMapChunkDto>,
    pub done: bool,
}

/// Stream a 2D overview one completed Minecraft chunk at a time.
pub async fn stream_world_map_preview(
    instance_id: String,
    folder: String,
    on_event: impl Fn(WorldMapStreamEventDto) -> DartFnFuture<bool> + Send + Sync + 'static,
) -> Result<(), String> {
    launcher::world_map::stream_world_map_preview(&instance_id, &folder, |event| {
        on_event(WorldMapStreamEventDto {
            min_chunk_x: event.min_chunk_x,
            min_chunk_z: event.min_chunk_z,
            max_chunk_x: event.max_chunk_x,
            max_chunk_z: event.max_chunk_z,
            chunks_done: event.chunks_done,
            chunks_total: event.chunks_total,
            chunk: event.chunk.map(|chunk| WorldMapChunkDto {
                chunk_x: chunk.chunk_x,
                chunk_z: chunk.chunk_z,
                rgba: chunk.rgba,
            }),
            done: event.done,
        })
    })
    .await
    .map_err(|error| error.to_string())
}

#[derive(Clone, Debug)]
pub struct ProcessDto {
    pub uuid: String,
    pub instance_id: String,
}

#[derive(Clone, Debug)]
pub struct GameVersionDto {
    pub id: String,
    pub type_: String,
    pub release_time: String,
}

pub async fn list_minecraft_versions() -> Result<Vec<GameVersionDto>, String> {
    let resource = state::resource_dir().await.map_err(|e| e.to_string())?;
    launcher::manifest::list_game_versions(&resource)
        .await
        .map(|v| {
            v.into_iter()
                .map(|g| GameVersionDto {
                    id: g.id,
                    type_: g.type_,
                    release_time: g.release_time,
                })
                .collect()
        })
        .map_err(|e| e.to_string())
}

#[derive(Clone, Debug)]
pub struct LoaderVersionDto {
    pub id: String,
    pub stable: bool,
}

pub async fn list_loader_versions(
    loader: String,
    game_version: String,
) -> Result<Vec<LoaderVersionDto>, String> {
    let resource = state::resource_dir().await.map_err(|e| e.to_string())?;
    launcher::manifest::list_loader_versions(&resource, &ModLoader::parse(&loader), &game_version)
        .await
        .map(|v| {
            v.into_iter()
                .map(|l| LoaderVersionDto {
                    id: l.id,
                    stable: l.stable,
                })
                .collect()
        })
        .map_err(|e| e.to_string())
}

#[derive(Clone, Debug)]
pub struct AccountDto {
    pub id: String,
    pub kind: String,
    pub username: String,
    pub uuid: String,
    pub auth_server_id: Option<String>,
    pub active: bool,
}

impl From<crate::state::models::Account> for AccountDto {
    fn from(a: crate::state::models::Account) -> Self {
        Self {
            id: a.id,
            kind: a.kind,
            username: a.username,
            uuid: a.uuid,
            auth_server_id: a.auth_server_id,
            active: a.active,
        }
    }
}

pub async fn list_accounts() -> Result<Vec<AccountDto>, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::list_accounts(&state.pool)
        .await
        .map(|v| v.into_iter().map(AccountDto::from).collect())
        .map_err(|e| e.to_string())
}

pub async fn create_offline_account(username: String) -> Result<AccountDto, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::upsert_offline_account(&state.pool, &username)
        .await
        .map(AccountDto::from)
        .map_err(|e| e.to_string())
}

pub async fn set_active_account(id: String) -> Result<(), String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::set_active_account(&state.pool, &id)
        .await
        .map_err(|e| e.to_string())
}

pub async fn remove_account(id: String) -> Result<(), String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::remove_account(&state.pool, &id)
        .await
        .map_err(|e| e.to_string())
}

#[derive(Clone, Debug)]
pub struct MsaLoginBeginDto {
    pub login_id: String,
    pub auth_url: String,
}

pub fn begin_msa_login() -> Result<MsaLoginBeginDto, String> {
    launcher::auth::begin_msa_login()
        .map(|l| MsaLoginBeginDto {
            login_id: l.login_id,
            auth_url: l.auth_url,
        })
        .map_err(|e| e.to_string())
}

pub async fn finish_msa_login(
    login_id: String,
    redirect_url: String,
) -> Result<AccountDto, String> {
    launcher::auth::finish_msa_login(&login_id, &redirect_url)
        .await
        .map(AccountDto::from)
        .map_err(|e| e.to_string())
}

#[derive(Clone, Debug)]
pub struct YggdrasilServiceDto {
    pub id: String,
    pub name: String,
    pub api_url: String,
    pub builtin: bool,
}

impl From<crate::state::models::YggdrasilService> for YggdrasilServiceDto {
    fn from(service: crate::state::models::YggdrasilService) -> Self {
        Self {
            id: service.id,
            name: service.name,
            api_url: service.api_url,
            builtin: service.builtin,
        }
    }
}

pub async fn list_yggdrasil_services() -> Result<Vec<YggdrasilServiceDto>, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::list_yggdrasil_services(&state.pool)
        .await
        .map(|services| {
            services
                .into_iter()
                .map(YggdrasilServiceDto::from)
                .collect()
        })
        .map_err(|e| e.to_string())
}

pub async fn save_yggdrasil_service(
    id: Option<String>,
    name: String,
    api_url: String,
) -> Result<YggdrasilServiceDto, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("服务名称不能为空".into());
    }
    let api_url =
        launcher::auth::normalize_yggdrasil_api_url(&api_url).map_err(|e| e.to_string())?;
    let id = id.unwrap_or_else(|| format!("custom:{}", uuid::Uuid::new_v4()));
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::upsert_yggdrasil_service(&state.pool, &id, name, &api_url)
        .await
        .map(YggdrasilServiceDto::from)
        .map_err(|e| e.to_string())
}

pub async fn remove_yggdrasil_service(id: String) -> Result<(), String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    db::remove_yggdrasil_service(&state.pool, &id)
        .await
        .map_err(|e| e.to_string())
}

#[derive(Clone, Debug)]
pub struct YggdrasilProfileDto {
    pub id: String,
    pub name: String,
    pub skin_url: Option<String>,
}

#[derive(Clone, Debug)]
pub struct YggdrasilLoginBeginDto {
    pub login_id: String,
    pub profiles: Vec<YggdrasilProfileDto>,
}

pub async fn begin_yggdrasil_login(
    service_id: String,
    username: String,
    password: String,
) -> Result<YggdrasilLoginBeginDto, String> {
    launcher::auth::begin_yggdrasil_login(&service_id, &username, &password)
        .await
        .map(|login| YggdrasilLoginBeginDto {
            login_id: login.login_id,
            profiles: login
                .profiles
                .into_iter()
                .map(|profile| YggdrasilProfileDto {
                    id: profile.id,
                    name: profile.name,
                    skin_url: profile.skin_url,
                })
                .collect(),
        })
        .map_err(|e| e.to_string())
}

pub async fn finish_yggdrasil_login(
    login_id: String,
    profile_id: String,
) -> Result<AccountDto, String> {
    launcher::auth::finish_yggdrasil_login(&login_id, &profile_id)
        .await
        .map(AccountDto::from)
        .map_err(|e| e.to_string())
}

#[derive(Clone, Debug)]
pub struct SkinDto {
    pub texture_key: String,
    pub name: Option<String>,
    pub section: Option<String>,
    pub variant: String,
    pub cape_id: Option<String>,
    pub texture_data_url: String,
    pub source: String,
    pub is_equipped: bool,
}

impl From<launcher::skins::SkinInfo> for SkinDto {
    fn from(s: launcher::skins::SkinInfo) -> Self {
        Self {
            texture_key: s.texture_key,
            name: s.name,
            section: s.section,
            variant: s.variant,
            cape_id: s.cape_id,
            texture_data_url: s.texture_data_url,
            source: s.source,
            is_equipped: s.is_equipped,
        }
    }
}

#[derive(Clone, Debug)]
pub struct CapeDto {
    pub id: String,
    pub name: String,
    pub texture_data_url: String,
    pub is_equipped: bool,
}

impl From<launcher::skins::CapeInfo> for CapeDto {
    fn from(c: launcher::skins::CapeInfo) -> Self {
        Self {
            id: c.id,
            name: c.name,
            texture_data_url: c.texture_data_url,
            is_equipped: c.is_equipped,
        }
    }
}

pub async fn list_available_skins() -> Result<Vec<SkinDto>, String> {
    launcher::skins::list_available_skins()
        .await
        .map(|v| v.into_iter().map(SkinDto::from).collect())
        .map_err(|e| e.to_string())
}

pub async fn list_available_capes() -> Result<Vec<CapeDto>, String> {
    launcher::skins::list_available_capes()
        .await
        .map(|v| v.into_iter().map(CapeDto::from).collect())
        .map_err(|e| e.to_string())
}

pub async fn normalize_skin_bytes(png_bytes: Vec<u8>) -> Result<Vec<u8>, String> {
    launcher::skins::normalize_skin_bytes(png_bytes)
        .await
        .map_err(|e| e.to_string())
}

pub async fn detect_skin_variant(png_bytes: Vec<u8>) -> Result<String, String> {
    launcher::skins::detect_skin_variant(png_bytes)
        .await
        .map_err(|e| e.to_string())
}

pub async fn save_custom_skin(
    png_bytes: Vec<u8>,
    name: Option<String>,
    variant: String,
    cape_id: Option<String>,
) -> Result<SkinDto, String> {
    launcher::skins::save_custom_skin(png_bytes, name, variant, cape_id)
        .await
        .map(SkinDto::from)
        .map_err(|e| e.to_string())
}

pub async fn remove_custom_skin(texture_key: String) -> Result<(), String> {
    launcher::skins::remove_custom_skin(texture_key)
        .await
        .map_err(|e| e.to_string())
}

pub async fn equip_skin(
    texture_key: String,
    variant: String,
    cape_id: Option<String>,
    texture_data_url: Option<String>,
) -> Result<(), String> {
    launcher::skins::equip_skin(texture_key, variant, cape_id, texture_data_url)
        .await
        .map_err(|e| e.to_string())
}

pub async fn bake_skin_preview(
    texture_data_url: String,
    variant: String,
    scale: u32,
) -> Result<Vec<u8>, String> {
    launcher::skins::bake_skin_preview(texture_data_url, variant, scale)
        .await
        .map_err(|e| e.to_string())
}

pub async fn install_modrinth_version(
    instance_id: String,
    version_id: String,
    project_type: Option<String>,
    install_deps: Option<bool>,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<String, String> {
    let cb: launcher::download::ProgressFn = Arc::new(move |p, m| {
        let fut = on_progress(p, m);
        tokio::spawn(async move {
            fut.await;
        });
    });
    launcher::content::install_modrinth_version(
        &instance_id,
        &version_id,
        project_type.as_deref(),
        install_deps.unwrap_or(true),
        Some(cb),
    )
    .await
    .map_err(|e| e.to_string())
}

pub async fn install_curseforge_file(
    instance_id: String,
    mod_id: u64,
    file_id: u64,
    project_type: Option<String>,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<String, String> {
    let cb: launcher::download::ProgressFn = Arc::new(move |p, m| {
        let fut = on_progress(p, m);
        tokio::spawn(async move {
            fut.await;
        });
    });
    launcher::content::install_curseforge_file(
        &instance_id,
        mod_id,
        file_id,
        project_type.as_deref(),
        Some(cb),
    )
    .await
    .map_err(|e| e.to_string())
}

pub async fn install_mrpack(
    instance_id: String,
    mrpack_path: String,
    java_path: Option<String>,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<(), String> {
    let cb: launcher::download::ProgressFn = Arc::new(move |p, m| {
        let fut = on_progress(p, m);
        tokio::spawn(async move {
            fut.await;
        });
    });
    launcher::content::install_mrpack(&instance_id, &mrpack_path, java_path, Some(cb))
        .await
        .map_err(|e| {
            eprintln!("[AML] install_mrpack({instance_id}): {e:#}");
            format!("{e:#}")
        })
}

pub async fn create_instance_from_modrinth_modpack(
    version_id: String,
    name: Option<String>,
    java_path: Option<String>,
    resume_instance_id: Option<String>,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<InstanceDto, String> {
    let cb: launcher::download::ProgressFn = Arc::new(move |p, m| {
        let fut = on_progress(p, m);
        tokio::spawn(async move {
            fut.await;
        });
    });
    launcher::content::create_instance_from_modrinth_modpack(
        &version_id,
        name,
        java_path,
        resume_instance_id.as_deref(),
        Some(cb),
    )
    .await
    .map(InstanceDto::from)
    .map_err(|e| {
        eprintln!("[AML] create_instance_from_modrinth_modpack({version_id}): {e:#}");
        format!("{e:#}")
    })
}

pub async fn create_instance_from_curseforge_modpack(
    mod_id: u64,
    file_id: u64,
    name: Option<String>,
    java_path: Option<String>,
    resume_instance_id: Option<String>,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<InstanceDto, String> {
    let cb: launcher::download::ProgressFn = Arc::new(move |p, m| {
        let fut = on_progress(p, m);
        tokio::spawn(async move {
            fut.await;
        });
    });
    launcher::content::create_instance_from_curseforge_modpack(
        mod_id,
        file_id,
        name,
        java_path,
        resume_instance_id.as_deref(),
        Some(cb),
    )
    .await
    .map(InstanceDto::from)
    .map_err(|e| {
        eprintln!(
            "[AML] create_instance_from_curseforge_modpack({mod_id}/{file_id}): {e:#}"
        );
        format!("{e:#}")
    })
}

#[derive(Clone, Debug)]
pub struct AssetPreviewEntryDto {
    pub id: String,
    pub namespace: String,
    pub name: String,
    pub category: String,
    pub model_path: Option<String>,
    pub texture_path: Option<String>,
    pub source_id: String,
    pub source_label: String,
    pub source_kind: String,
}

impl From<launcher::asset_preview::AssetPreviewEntry> for AssetPreviewEntryDto {
    fn from(e: launcher::asset_preview::AssetPreviewEntry) -> Self {
        Self {
            id: e.id,
            namespace: e.namespace,
            name: e.name,
            category: e.category,
            model_path: e.model_path,
            texture_path: e.texture_path,
            source_id: e.source_id,
            source_label: e.source_label,
            source_kind: e.source_kind,
        }
    }
}

#[derive(Clone, Debug)]
pub struct AssetPreviewCatalogDto {
    pub fingerprint: String,
    pub scanned_at: String,
    pub entries: Vec<AssetPreviewEntryDto>,
}

impl From<launcher::asset_preview::AssetPreviewCatalog> for AssetPreviewCatalogDto {
    fn from(c: launcher::asset_preview::AssetPreviewCatalog) -> Self {
        Self {
            fingerprint: c.fingerprint,
            scanned_at: c.scanned_at,
            entries: c
                .entries
                .into_iter()
                .map(AssetPreviewEntryDto::from)
                .collect(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct ModelFaceDto {
    pub texture_index: i32,
    pub u0: f64,
    pub v0: f64,
    pub u1: f64,
    pub v1: f64,
}

#[derive(Clone, Debug)]
pub struct ModelElementDto {
    pub from_x: f64,
    pub from_y: f64,
    pub from_z: f64,
    pub to_x: f64,
    pub to_y: f64,
    pub to_z: f64,
    pub north: Option<ModelFaceDto>,
    pub south: Option<ModelFaceDto>,
    pub east: Option<ModelFaceDto>,
    pub west: Option<ModelFaceDto>,
    pub up: Option<ModelFaceDto>,
    pub down: Option<ModelFaceDto>,
}

#[derive(Clone, Debug)]
pub struct ResolvedAssetPreviewDto {
    pub entry_id: String,
    pub preview_kind: String,
    pub elements: Vec<ModelElementDto>,
    pub textures: Vec<Vec<u8>>,
    pub gui_rotation_x: Option<f64>,
    pub gui_rotation_y: Option<f64>,
    pub gui_rotation_z: Option<f64>,
    pub gui_scale: Option<f64>,
}

fn face_to_dto(face: &launcher::asset_preview::ModelFace) -> ModelFaceDto {
    ModelFaceDto {
        texture_index: face.texture_index as i32,
        u0: face.u0,
        v0: face.v0,
        u1: face.u1,
        v1: face.v1,
    }
}

fn element_to_dto(e: &launcher::asset_preview::ModelElement) -> ModelElementDto {
    ModelElementDto {
        from_x: e.from[0],
        from_y: e.from[1],
        from_z: e.from[2],
        to_x: e.to[0],
        to_y: e.to[1],
        to_z: e.to[2],
        north: e.faces.get("north").map(face_to_dto),
        south: e.faces.get("south").map(face_to_dto),
        east: e.faces.get("east").map(face_to_dto),
        west: e.faces.get("west").map(face_to_dto),
        up: e.faces.get("up").map(face_to_dto),
        down: e.faces.get("down").map(face_to_dto),
    }
}

pub async fn scan_instance_assets(
    instance_id: String,
    force: bool,
) -> Result<AssetPreviewCatalogDto, String> {
    launcher::asset_preview::scan_instance_assets(&instance_id, force)
        .await
        .map(AssetPreviewCatalogDto::from)
        .map_err(|e| e.to_string())
}

pub async fn resolve_asset_preview(
    instance_id: String,
    entry_id: String,
) -> Result<ResolvedAssetPreviewDto, String> {
    launcher::asset_preview::resolve_asset_preview(&instance_id, &entry_id)
        .await
        .map(|r| ResolvedAssetPreviewDto {
            entry_id: r.entry_id,
            preview_kind: r.preview_kind,
            elements: r.elements.iter().map(element_to_dto).collect(),
            textures: r.textures,
            gui_rotation_x: r.gui_rotation.map(|v| v[0]),
            gui_rotation_y: r.gui_rotation.map(|v| v[1]),
            gui_rotation_z: r.gui_rotation.map(|v| v[2]),
            gui_scale: r.gui_scale,
        })
        .map_err(|e| e.to_string())
}

#[derive(Clone, Debug)]
pub struct PackContentFileDto {
    pub path: String,
    pub name: String,
    pub size_bytes: u64,
    pub icon_url: Option<String>,
    pub title: Option<String>,
}

#[derive(Clone, Debug)]
pub struct PackContentCategoryDto {
    pub id: String,
    pub label: String,
    pub file_count: u32,
    pub total_bytes: u64,
    pub files: Vec<PackContentFileDto>,
}

#[derive(Clone, Debug)]
pub struct PackImportPreviewDto {
    pub kind: String,
    pub kind_label: String,
    pub name: String,
    pub version: Option<String>,
    pub game_version: Option<String>,
    pub loader: Option<String>,
    pub categories: Vec<PackContentCategoryDto>,
    pub has_cover: bool,
    pub cover_png: Option<Vec<u8>>,
}

#[derive(Clone, Debug)]
pub struct PackExportPreviewDto {
    pub name: String,
    pub game_version: String,
    pub loader: String,
    pub categories: Vec<PackContentCategoryDto>,
}

fn map_file(f: launcher::pack::PackContentFile) -> PackContentFileDto {
    PackContentFileDto {
        path: f.path,
        name: f.name,
        size_bytes: f.size_bytes,
        icon_url: f.icon_url,
        title: f.title,
    }
}

fn map_category(c: launcher::pack::PackContentCategory) -> PackContentCategoryDto {
    PackContentCategoryDto {
        id: c.id,
        label: c.label,
        file_count: c.file_count,
        total_bytes: c.total_bytes,
        files: c.files.into_iter().map(map_file).collect(),
    }
}

pub async fn detect_pack_format(path: String) -> Result<String, String> {
    launcher::pack::detect_pack_file(std::path::Path::new(&path))
        .map(|k| k.as_str().to_string())
        .map_err(|e| format!("{e:#}"))
}

pub async fn preview_pack_file(path: String) -> Result<PackImportPreviewDto, String> {
    launcher::pack::preview_pack_file(std::path::Path::new(&path))
        .await
        .map(|p| PackImportPreviewDto {
            kind: p.kind,
            kind_label: p.kind_label,
            name: p.name,
            version: p.version,
            game_version: p.game_version,
            loader: p.loader,
            categories: p.categories.into_iter().map(map_category).collect(),
            has_cover: p.has_cover,
            cover_png: p.cover_png,
        })
        .map_err(|e| format!("{e:#}"))
}

pub async fn preview_instance_export(
    instance_id: String,
) -> Result<PackExportPreviewDto, String> {
    let st = state::try_state().map_err(|e| e.to_string())?;
    let instance = db::get_instance(&st.pool, &instance_id)
        .await
        .map_err(|e| format!("{e:#}"))?;
    let categories = launcher::pack::preview_instance_export(&instance_id)
        .await
        .map_err(|e| format!("{e:#}"))?;
    Ok(PackExportPreviewDto {
        name: instance.name,
        game_version: instance.game_version,
        loader: instance.loader,
        categories: categories.into_iter().map(map_category).collect(),
    })
}

pub async fn create_instance_from_pack_file(
    path: String,
    name: Option<String>,
    java_path: Option<String>,
    resume_instance_id: Option<String>,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<InstanceDto, String> {
    let cb: launcher::download::ProgressFn = Arc::new(move |p, m| {
        let fut = on_progress(p, m);
        tokio::spawn(async move {
            fut.await;
        });
    });
    launcher::pack::create_instance_from_pack_file_resumable(
        &path,
        name,
        java_path,
        resume_instance_id.as_deref(),
        Some(cb),
    )
    .await
    .map(InstanceDto::from)
    .map_err(|e| {
        eprintln!("[AML] create_instance_from_pack_file({path}): {e:#}");
        format!("{e:#}")
    })
}

pub async fn create_instance_from_mmc_folder(
    folder: String,
    name: Option<String>,
    java_path: Option<String>,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<InstanceDto, String> {
    let cb: launcher::download::ProgressFn = Arc::new(move |p, m| {
        let fut = on_progress(p, m);
        tokio::spawn(async move {
            fut.await;
        });
    });
    launcher::pack::create_instance_from_mmc_folder(&folder, name, java_path, Some(cb))
        .await
        .map(InstanceDto::from)
        .map_err(|e| {
            eprintln!("[AML] create_instance_from_mmc_folder({folder}): {e:#}");
            format!("{e:#}")
        })
}

pub async fn export_instance_mrpack(
    instance_id: String,
    export_path: String,
    pack_name: Option<String>,
    version_id: Option<String>,
    description: Option<String>,
    include_ids: Option<Vec<String>>,
    include_paths: Option<Vec<String>>,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<(), String> {
    export_instance_pack(
        instance_id,
        export_path,
        "mrpack".into(),
        pack_name,
        version_id,
        description,
        include_ids,
        include_paths,
        on_progress,
    )
    .await
}

/// Export an instance pack. `format`: `mrpack` | `multimc` | `mcbbs`.
///
/// `include_ids` accepts category ids: mods / resourcepacks / shaderpacks /
/// datapacks / config / options / saves. Empty/None → defaults (no saves).
/// `include_paths` optionally restricts to specific relative file paths.
pub async fn export_instance_pack(
    instance_id: String,
    export_path: String,
    format: String,
    pack_name: Option<String>,
    version_id: Option<String>,
    description: Option<String>,
    include_ids: Option<Vec<String>>,
    include_paths: Option<Vec<String>>,
    on_progress: impl Fn(f64, String) -> DartFnFuture<()> + Send + Sync + 'static,
) -> Result<(), String> {
    let cb: launcher::download::ProgressFn = Arc::new(move |p, m| {
        let fut = on_progress(p, m);
        tokio::spawn(async move {
            fut.await;
        });
    });
    launcher::pack::export_instance_pack(
        &instance_id,
        &export_path,
        &format,
        pack_name,
        version_id,
        description,
        include_ids,
        include_paths,
        Some(cb),
    )
    .await
    .map_err(|e| {
        eprintln!("[AML] export_instance_pack({instance_id}, {format}): {e:#}");
        format!("{e:#}")
    })
}

/// Create a desktop shortcut that launches AML with an `aml://launch/…` argument.
///
/// On Windows this writes a `.lnk` pointing at the current executable.
/// `server_address` and `world_folder` are mutually exclusive.
///
/// `icon` may be a local image path or a `data:image/...;base64,…` URL. When omitted,
/// server shortcuts prefer the `servers.dat` favicon, otherwise the instance icon.
pub async fn create_desktop_shortcut(
    display_name: String,
    output_path: String,
    instance_id: String,
    server_address: Option<String>,
    world_folder: Option<String>,
    icon: Option<String>,
) -> Result<String, String> {
    let path = launcher::shortcuts::create_desktop_shortcut(
        &display_name,
        std::path::PathBuf::from(output_path),
        &instance_id,
        server_address.as_deref(),
        world_folder.as_deref(),
        icon.as_deref(),
    )
    .await
    .map_err(|e| format!("{e:#}"))?;
    Ok(path.to_string_lossy().into_owned())
}
