use anyhow::{anyhow, Context, Result};
use serde::Deserialize;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use zip::ZipArchive;

use crate::state::models::ModLoader;

use super::detect::{read_zip_entry, zip_entry_prefix};

#[derive(Debug, Clone)]
pub struct MmcPackMeta {
    pub name: String,
    pub game_version: String,
    pub loader: ModLoader,
    pub loader_version: Option<String>,
    pub minecraft_prefix: String,
    pub zip_prefix: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MmcPackJson {
    components: Vec<MmcComponent>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MmcComponent {
    uid: String,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    disabled: bool,
}

pub fn read_mmc_meta_from_zip(data: &[u8]) -> Result<MmcPackMeta> {
    let mut archive = ZipArchive::new(Cursor::new(data))?;
    let zip_prefix = zip_entry_prefix(&mut archive, "mmc-pack.json");
    let pack_text = read_zip_entry(&mut archive, "mmc-pack.json")?;
    let pack: MmcPackJson =
        serde_json::from_str(&pack_text).context("解析 mmc-pack.json 失败")?;

    let mut game_version = String::new();
    let mut loader = ModLoader::Vanilla;
    let mut loader_version = None;
    for c in pack.components {
        if c.disabled {
            continue;
        }
        let uid = c.uid.to_lowercase();
        let ver = c.version.unwrap_or_default();
        if uid.starts_with("net.minecraft") {
            game_version = ver;
        } else if uid.contains("fabric-loader") || uid.contains("fabricmc.fabric-loader") {
            loader = ModLoader::Fabric;
            loader_version = Some(ver);
        } else if uid.contains("quilt-loader") || uid.contains("quiltmc.quilt-loader") {
            loader = ModLoader::Quilt;
            loader_version = Some(ver);
        } else if uid.contains("neoforged") || uid.contains("neoforge") {
            loader = ModLoader::NeoForge;
            loader_version = Some(ver);
        } else if uid.contains("minecraftforge") || uid == "net.minecraftforge" {
            loader = ModLoader::Forge;
            loader_version = Some(ver);
        }
    }
    if game_version.is_empty() {
        return Err(anyhow!("mmc-pack.json 缺少 Minecraft 版本"));
    }

    let name = read_zip_entry(&mut archive, "instance.cfg")
        .ok()
        .and_then(|cfg| parse_ini_name(&cfg))
        .unwrap_or_else(|| "MultiMC Instance".into());

    // Prefer minecraft/ then .minecraft/
    let minecraft_prefix = if zip_has(&mut archive, &format!("{zip_prefix}minecraft/")) {
        format!("{zip_prefix}minecraft/")
    } else if zip_has(&mut archive, &format!("{zip_prefix}.minecraft/")) {
        format!("{zip_prefix}.minecraft/")
    } else {
        return Err(anyhow!("MultiMC 包缺少 minecraft/ 或 .minecraft/ 目录"));
    };

    Ok(MmcPackMeta {
        name,
        game_version,
        loader,
        loader_version,
        minecraft_prefix,
        zip_prefix,
    })
}

fn zip_has<R: std::io::Read + std::io::Seek>(archive: &mut ZipArchive<R>, prefix: &str) -> bool {
    (0..archive.len()).any(|i| {
        archive
            .by_index(i)
            .ok()
            .map(|f| f.name().replace('\\', "/").starts_with(prefix))
            .unwrap_or(false)
    })
}

fn parse_ini_name(cfg: &str) -> Option<String> {
    for line in cfg.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("name=") {
            let v = rest.trim();
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
        if let Some(rest) = line.strip_prefix("Name=") {
            let v = rest.trim();
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

pub fn extract_mmc_minecraft(data: &[u8], dest: &Path, minecraft_prefix: &str) -> Result<()> {
    let mut archive = ZipArchive::new(Cursor::new(data))?;
    super::super::content::extract_overrides(&mut archive, dest, minecraft_prefix)
}

/// Directory-based MultiMC instance import (not zip).
pub fn read_mmc_meta_from_dir(instance_dir: &Path) -> Result<(MmcPackMeta, PathBuf)> {
    let pack_path = instance_dir.join("mmc-pack.json");
    let pack_text = std::fs::read_to_string(&pack_path).context("读取 mmc-pack.json 失败")?;
    let pack: MmcPackJson =
        serde_json::from_str(&pack_text).context("解析 mmc-pack.json 失败")?;

    let mut game_version = String::new();
    let mut loader = ModLoader::Vanilla;
    let mut loader_version = None;
    for c in pack.components {
        if c.disabled {
            continue;
        }
        let uid = c.uid.to_lowercase();
        let ver = c.version.unwrap_or_default();
        if uid.starts_with("net.minecraft") {
            game_version = ver;
        } else if uid.contains("fabric-loader") {
            loader = ModLoader::Fabric;
            loader_version = Some(ver);
        } else if uid.contains("quilt-loader") {
            loader = ModLoader::Quilt;
            loader_version = Some(ver);
        } else if uid.contains("neoforged") || uid.contains("neoforge") {
            loader = ModLoader::NeoForge;
            loader_version = Some(ver);
        } else if uid.contains("minecraftforge") {
            loader = ModLoader::Forge;
            loader_version = Some(ver);
        }
    }
    if game_version.is_empty() {
        return Err(anyhow!("mmc-pack.json 缺少 Minecraft 版本"));
    }

    let name = std::fs::read_to_string(instance_dir.join("instance.cfg"))
        .ok()
        .and_then(|c| parse_ini_name(&c))
        .unwrap_or_else(|| {
            instance_dir
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_else(|| "MultiMC Instance".into())
        });

    let minecraft_dir = {
        let a = instance_dir.join("minecraft");
        let b = instance_dir.join(".minecraft");
        if a.is_dir() {
            a
        } else if b.is_dir() {
            b
        } else {
            return Err(anyhow!("实例缺少 minecraft/ 或 .minecraft/"));
        }
    };

    Ok((
        MmcPackMeta {
            name,
            game_version,
            loader,
            loader_version,
            minecraft_prefix: String::new(),
            zip_prefix: String::new(),
        },
        minecraft_dir,
    ))
}
