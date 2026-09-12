//! Instance worlds: parse `saves/*/level.dat` + `icon.png`, and `servers.dat`.
//! Parse world and server list data from the instance directory.

use anyhow::{anyhow, Context, Result};
use chrono::{TimeZone, Utc};
use quartz_nbt::NbtCompound;
use serde::Deserialize;
use std::io::Cursor;
use std::path::{Path, PathBuf};

use crate::state::db;
use crate::state::{resource_dir, try_state};

use super::dirs;

#[derive(Debug, Clone)]
pub struct WorldInfo {
    pub kind: String, // singleplayer | server
    pub name: String,
    pub folder: String,    // saves folder name, or server address for server
    pub game_mode: String, // survival|creative|adventure|spectator|""
    pub hardcore: bool,
    pub last_played_ms: Option<i64>,
    pub icon_path: Option<String>,
    pub icon_data_url: Option<String>, // servers.dat base64 → data URL
    pub server_address: Option<String>,
    pub server_index: Option<i32>,
    /// Number of zip backups under `backups/worlds/{folder}/` (singleplayer only).
    pub backup_count: u32,
}

fn count_world_backup_zips(instance_dir: &Path, folder: &str) -> u32 {
    let dir = instance_dir.join("backups").join("worlds").join(folder);
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    entries
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path().is_file()
                && e.path()
                    .extension()
                    .map(|ext| ext.eq_ignore_ascii_case("zip"))
                    .unwrap_or(false)
        })
        .count() as u32
}

pub async fn list_instance_worlds(instance_id: &str) -> Result<Vec<WorldInfo>> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let root = dirs::instance_dir(&resource, &instance.path);

    let mut out = Vec::new();
    out.extend(list_singleplayer(&root).await?);
    out.extend(list_servers(&state.pool, instance_id, &root).await?);

    out.sort_by(|a, b| {
        b.last_played_ms
            .unwrap_or(0)
            .cmp(&a.last_played_ms.unwrap_or(0))
    });
    Ok(out)
}

async fn list_singleplayer(instance_dir: &Path) -> Result<Vec<WorldInfo>> {
    let saves = instance_dir.join("saves");
    if !saves.exists() {
        return Ok(vec![]);
    }
    let mut out = Vec::new();
    let mut entries = tokio::fs::read_dir(&saves).await?;
    while let Some(entry) = entries.next_entry().await? {
        if !entry.file_type().await?.is_dir() {
            continue;
        }
        match read_singleplayer_world(instance_dir, entry.path()).await {
            Ok(w) => out.push(w),
            Err(e) => {
                tracing::warn!("skip world {}: {e}", entry.path().display());
            }
        }
    }
    Ok(out)
}

async fn read_singleplayer_world(instance_dir: &Path, world_path: PathBuf) -> Result<WorldInfo> {
    let level_dat = world_path.join("level.dat");
    let raw = tokio::fs::read(&level_dat)
        .await
        .with_context(|| format!("read {}", level_dat.display()))?;
    let (root, _) =
        quartz_nbt::io::read_nbt(&mut Cursor::new(raw), quartz_nbt::io::Flavor::GzCompressed)
            .context("parse level.dat")?;

    let data = root
        .get::<_, &NbtCompound>("Data")
        .map_err(|_| anyhow!("level.dat missing Data"))?;

    let level_name = data
        .get::<_, &str>("LevelName")
        .unwrap_or_default()
        .to_string();
    let last_played = data.get::<_, i64>("LastPlayed").unwrap_or(0);
    let game_type = data.get::<_, i32>("GameType").unwrap_or(0);
    let hardcore = data.get::<_, i8>("hardcore").unwrap_or(0) != 0;

    let folder = world_path
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "world".into());

    let icon_path = {
        let icon = world_path.join("icon.png");
        if icon.exists() {
            Some(icon.to_string_lossy().to_string())
        } else {
            None
        }
    };

    let game_mode = match game_type {
        1 => "creative",
        2 => "adventure",
        3 => "spectator",
        _ => "survival",
    }
    .into();

    let last_played_ms = if last_played > 0 {
        Utc.timestamp_millis_opt(last_played)
            .single()
            .map(|_| last_played)
    } else {
        None
    };

    Ok(WorldInfo {
        kind: "singleplayer".into(),
        name: if level_name.is_empty() {
            folder.clone()
        } else {
            level_name
        },
        folder: folder.clone(),
        game_mode,
        hardcore,
        last_played_ms,
        icon_path,
        icon_data_url: None,
        server_address: None,
        server_index: None,
        backup_count: count_world_backup_zips(instance_dir, &folder),
    })
}

async fn list_servers(
    pool: &sqlx::SqlitePool,
    instance_id: &str,
    instance_dir: &Path,
) -> Result<Vec<WorldInfo>> {
    let servers = servers_data::read(instance_dir).await?;
    let joins = db::get_server_joins(pool, instance_id)
        .await
        .unwrap_or_default();
    let mut out = Vec::new();
    for (index, server) in servers.into_iter().enumerate() {
        if server.hidden {
            continue;
        }
        let icon_data_url = server
            .icon
            .as_deref()
            .and_then(crate::launcher::server_ping::normalize_favicon);
        let last_played_ms = super::server_address::parse_server_address(&server.ip)
            .ok()
            .and_then(|(host, port)| joins.get(&(host, port)).copied());
        out.push(WorldInfo {
            kind: "server".into(),
            name: if server.name.is_empty() {
                server.ip.clone()
            } else {
                server.name
            },
            folder: server.ip.clone(),
            game_mode: String::new(),
            hardcore: false,
            last_played_ms,
            icon_path: None,
            icon_data_url,
            server_address: Some(server.ip),
            server_index: Some(index as i32),
            backup_count: 0,
        });
    }
    Ok(out)
}

pub async fn delete_instance_world(instance_id: &str, folder: &str) -> Result<()> {
    if folder.is_empty() || folder.contains("..") || folder.contains('/') || folder.contains('\\') {
        anyhow::bail!("invalid world folder");
    }
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let world = dirs::instance_dir(&resource, &instance.path)
        .join("saves")
        .join(folder);
    if !world.exists() {
        anyhow::bail!("world not found");
    }
    tokio::fs::remove_dir_all(&world)
        .await
        .with_context(|| format!("delete {}", world.display()))?;
    Ok(())
}

/// Add a multiplayer server entry to `servers.dat`.
pub async fn add_instance_server(
    instance_id: &str,
    name: &str,
    address: &str,
) -> Result<i32> {
    let name = name.trim();
    let address = address.trim();
    if address.is_empty() {
        anyhow::bail!("服务器地址不能为空");
    }
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);

    let mut servers = servers_data::read(&instance_dir).await?;
    // Insert before the first hidden entry (Minecraft convention).
    let insert_index = servers
        .iter()
        .position(|s| s.hidden)
        .unwrap_or(servers.len());
    servers.insert(
        insert_index,
        servers_data::ServerData {
            hidden: false,
            icon: None,
            ip: address.to_string(),
            name: if name.is_empty() {
                address.to_string()
            } else {
                name.to_string()
            },
            accept_textures: None,
        },
    );
    servers_data::write(&instance_dir, &servers).await?;
    Ok(insert_index as i32)
}

/// Remove a multiplayer server by index in `servers.dat`.
pub async fn remove_instance_server(instance_id: &str, index: i32) -> Result<()> {
    if index < 0 {
        anyhow::bail!("无效的服务器索引");
    }
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let mut servers = servers_data::read(&instance_dir).await?;
    let idx = index as usize;
    if servers.get(idx).map(|s| s.hidden).unwrap_or(true) {
        anyhow::bail!("找不到可删除的服务器");
    }
    servers.remove(idx);
    servers_data::write(&instance_dir, &servers).await?;
    Ok(())
}

/// Edit a multiplayer server by index.
pub async fn edit_instance_server(
    instance_id: &str,
    index: i32,
    name: &str,
    address: &str,
) -> Result<()> {
    if index < 0 {
        anyhow::bail!("无效的服务器索引");
    }
    let name = name.trim();
    let address = address.trim();
    if address.is_empty() {
        anyhow::bail!("服务器地址不能为空");
    }
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let mut servers = servers_data::read(&instance_dir).await?;
    let idx = index as usize;
    let server = servers
        .get_mut(idx)
        .filter(|s| !s.hidden)
        .ok_or_else(|| anyhow!("找不到可编辑的服务器"))?;
    server.name = if name.is_empty() {
        address.to_string()
    } else {
        name.to_string()
    };
    server.ip = address.to_string();
    servers_data::write(&instance_dir, &servers).await?;
    Ok(())
}

/// Raw favicon payload from `servers.dat` for [address], if present.
pub async fn find_server_icon(instance_id: &str, address: &str) -> Result<Option<String>> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let target = super::server_address::parse_server_address(address).ok();
    let servers = servers_data::read(&instance_dir).await?;
    for server in servers {
        if server.hidden {
            continue;
        }
        let matched = server.ip.eq_ignore_ascii_case(address.trim())
            || target
                .as_ref()
                .and_then(|(h, p)| {
                    super::server_address::parse_server_address(&server.ip)
                        .ok()
                        .map(|(sh, sp)| sh.eq_ignore_ascii_case(h) && sp == *p)
                })
                .unwrap_or(false);
        if matched {
            return Ok(server.icon);
        }
    }
    Ok(None)
}

mod servers_data {
    use anyhow::{Context, Result};
    use serde::{Deserialize, Serialize};
    use std::path::Path;

    #[derive(Serialize, Deserialize, Debug, Clone)]
    #[serde(rename_all = "camelCase")]
    pub struct ServerData {
        #[serde(default)]
        pub hidden: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub icon: Option<String>,
        #[serde(default)]
        pub ip: String,
        #[serde(default)]
        pub name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub accept_textures: Option<bool>,
    }

    pub async fn read(instance_dir: &Path) -> Result<Vec<ServerData>> {
        #[derive(Deserialize, Debug)]
        struct ServersData {
            #[serde(default)]
            servers: Vec<ServerData>,
        }

        let path = instance_dir.join("servers.dat");
        if !path.exists() {
            return Ok(vec![]);
        }
        let bytes = tokio::fs::read(&path)
            .await
            .with_context(|| format!("read {}", path.display()))?;
        let (data, _): (ServersData, _) =
            quartz_nbt::serde::deserialize(&bytes, quartz_nbt::io::Flavor::Uncompressed)
                .context("parse servers.dat")?;
        Ok(data.servers)
    }

    pub async fn write(instance_dir: &Path, servers: &[ServerData]) -> Result<()> {
        #[derive(Serialize, Debug)]
        struct ServersData<'a> {
            servers: &'a [ServerData],
        }

        let path = instance_dir.join("servers.dat");
        let data = quartz_nbt::serde::serialize(
            &ServersData { servers },
            None,
            quartz_nbt::io::Flavor::Uncompressed,
        )
        .context("serialize servers.dat")?;
        tokio::fs::write(&path, data)
            .await
            .with_context(|| format!("write {}", path.display()))?;
        Ok(())
    }
}
