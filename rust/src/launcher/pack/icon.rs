//! Locate pack cover / instance icon inside modpack zips.

use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use zip::ZipArchive;

/// Preferred paths (mrpack / CF / MCBBS).
const PRIORITY: &[&str] = &[
    "icon.png",
    "overrides/icon.png",
    "client-overrides/icon.png",
    "override/icon.png",
    "minecraft/icon.png",
];

/// Returns `(zip_entry_path, png_bytes)` when a pack ships an icon/cover.
pub fn find_pack_icon_bytes(data: &[u8]) -> Option<(String, Vec<u8>)> {
    let mut archive = ZipArchive::new(Cursor::new(data)).ok()?;

    for name in PRIORITY {
        if let Some(bytes) = read_entry(&mut archive, name) {
            return Some(((*name).to_string(), bytes));
        }
    }

    // MultiMC: `{instance}/icon.png` or `{instance}/minecraft/icon.png`
    let mut best: Option<(usize, String, usize)> = None; // index, path, depth
    for i in 0..archive.len() {
        let Ok(file) = archive.by_index(i) else {
            continue;
        };
        if file.is_dir() {
            continue;
        }
        let name = file.name().replace('\\', "/");
        let lower = name.to_ascii_lowercase();
        if !lower.ends_with("/icon.png") && lower != "icon.png" {
            continue;
        }
        let depth = name.matches('/').count();
        if depth > 3 {
            continue;
        }
        let size = file.size();
        if size == 0 || size > 8 * 1024 * 1024 {
            continue;
        }
        let take = match &best {
            None => true,
            Some((_, _, prev_depth)) => depth < *prev_depth,
        };
        if take {
            best = Some((i, name, depth));
        }
    }

    if let Some((idx, path, _)) = best {
        let mut file = archive.by_index(idx).ok()?;
        let mut buf = Vec::new();
        file.read_to_end(&mut buf).ok()?;
        if buf.is_empty() {
            return None;
        }
        return Some((path, buf));
    }
    None
}

fn read_entry<R: std::io::Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
) -> Option<Vec<u8>> {
    let mut file = archive.by_name(name).ok()?;
    if file.is_dir() {
        return None;
    }
    let mut buf = Vec::new();
    file.read_to_end(&mut buf).ok()?;
    if buf.is_empty() {
        return None;
    }
    Some(buf)
}

/// Write the first matching pack icon into `[dest_root]/icon.png`.
pub fn try_extract_pack_icon_to(data: &[u8], dest_root: &Path) -> std::io::Result<Option<PathBuf>> {
    let Some((_, bytes)) = find_pack_icon_bytes(data) else {
        return Ok(None);
    };
    write_icon(dest_root, &bytes)
}

/// Same as [try_extract_pack_icon_to] but for an already-open archive (mrpack install).
pub fn try_extract_pack_icon_from_archive<R: std::io::Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    dest_root: &Path,
) -> std::io::Result<Option<PathBuf>> {
    for name in PRIORITY {
        if let Some(bytes) = read_entry(archive, name) {
            return write_icon(dest_root, &bytes);
        }
    }
    Ok(None)
}

fn write_icon(dest_root: &Path, bytes: &[u8]) -> std::io::Result<Option<PathBuf>> {
    let dest = dest_root.join("icon.png");
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&dest, bytes)?;
    Ok(Some(dest))
}
