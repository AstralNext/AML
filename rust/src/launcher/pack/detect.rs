use anyhow::{anyhow, Result};
use std::io::{Cursor, Read};
use std::path::Path;
use zip::ZipArchive;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PackKind {
    Mrpack,
    CurseForge,
    MultiMc,
    Mcbbs,
}

impl PackKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mrpack => "mrpack",
            Self::CurseForge => "curseforge",
            Self::MultiMc => "multimc",
            Self::Mcbbs => "mcbbs",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Mrpack => "Modrinth",
            Self::CurseForge => "CurseForge",
            Self::MultiMc => "MultiMC",
            Self::Mcbbs => "MCBBS",
        }
    }
}

pub fn detect_pack_file(path: &Path) -> Result<PackKind> {
    let data = std::fs::read(path)?;
    detect_pack_bytes(&data)
}

pub fn detect_pack_bytes(data: &[u8]) -> Result<PackKind> {
    let mut archive = ZipArchive::new(Cursor::new(data))
        .map_err(|e| anyhow!("不是有效的 zip/mrpack：{e}"))?;

    let names: Vec<String> = (0..archive.len())
        .filter_map(|i| archive.by_index(i).ok().map(|f| f.name().replace('\\', "/")))
        .collect();

    let has = |needle: &str| {
        names.iter().any(|n| {
            let n = n.trim_start_matches("./");
            n == needle
                || n.ends_with(&format!("/{needle}"))
                || n.strip_prefix(needle)
                    .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
        })
    };

    // Priority: mrpack → mcbbs → curseforge → multimc
    if has("modrinth.index.json") {
        return Ok(PackKind::Mrpack);
    }
    if has("mcbbs.packmeta") {
        return Ok(PackKind::Mcbbs);
    }
    if has("manifest.json") {
        // Confirm CF-style when possible.
        if let Ok(text) = read_zip_entry(&mut archive, "manifest.json") {
            if text.contains("minecraftModpack")
                || text.contains("\"projectID\"")
                || text.contains("\"files\"")
            {
                return Ok(PackKind::CurseForge);
            }
        } else {
            return Ok(PackKind::CurseForge);
        }
    }
    if has("mmc-pack.json") && (has("instance.cfg") || has("minecraft/") || has(".minecraft/")) {
        return Ok(PackKind::MultiMc);
    }
    // Nested MultiMC export (single top-level folder).
    if let Some(prefix) = single_root_prefix(&names) {
        let nested = |name: &str| names.iter().any(|n| n == &format!("{prefix}{name}"));
        if nested("mmc-pack.json") {
            return Ok(PackKind::MultiMc);
        }
        if nested("modrinth.index.json") {
            return Ok(PackKind::Mrpack);
        }
        if nested("mcbbs.packmeta") {
            return Ok(PackKind::Mcbbs);
        }
        if nested("manifest.json") {
            return Ok(PackKind::CurseForge);
        }
    }

    Err(anyhow!(
        "无法识别整合包格式（需要 modrinth.index.json / manifest.json / mcbbs.packmeta / mmc-pack.json）"
    ))
}

fn single_root_prefix(names: &[String]) -> Option<String> {
    let mut roots = std::collections::BTreeSet::new();
    for n in names {
        let n = n.trim_start_matches("./");
        if n.is_empty() {
            continue;
        }
        if let Some((root, _)) = n.split_once('/') {
            if !root.is_empty() {
                roots.insert(root.to_string());
            }
        } else {
            return None;
        }
    }
    if roots.len() == 1 {
        roots.into_iter().next().map(|r| format!("{r}/"))
    } else {
        None
    }
}

pub(crate) fn read_zip_entry<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
) -> Result<String> {
    // Try exact and nested single-root paths.
    let candidates = {
        let mut v = vec![name.to_string(), format!("./{name}")];
        let names: Vec<String> = (0..archive.len())
            .filter_map(|i| archive.by_index(i).ok().map(|f| f.name().replace('\\', "/")))
            .collect();
        if let Some(prefix) = single_root_prefix(&names) {
            v.push(format!("{prefix}{name}"));
        }
        v
    };
    for cand in candidates {
        if let Ok(mut file) = archive.by_name(&cand) {
            let mut text = String::new();
            file.read_to_string(&mut text)?;
            return Ok(text);
        }
    }
    // Case-insensitive scan.
    for i in 0..archive.len() {
        let mut file = archive.by_index(i)?;
        let n = file.name().replace('\\', "/");
        let leaf = n.rsplit('/').next().unwrap_or(&n);
        if leaf.eq_ignore_ascii_case(name) {
            let mut text = String::new();
            file.read_to_string(&mut text)?;
            return Ok(text);
        }
    }
    Err(anyhow!("zip 中找不到 {name}"))
}

pub(crate) fn zip_entry_prefix<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    marker: &str,
) -> String {
    let names: Vec<String> = (0..archive.len())
        .filter_map(|i| archive.by_index(i).ok().map(|f| f.name().replace('\\', "/")))
        .collect();
    for n in &names {
        let n = n.trim_start_matches("./");
        if n == marker {
            return String::new();
        }
        if let Some(prefix) = n.strip_suffix(marker) {
            if prefix.is_empty() || prefix.ends_with('/') {
                return prefix.to_string();
            }
        }
    }
    String::new()
}
