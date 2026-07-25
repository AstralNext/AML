use anyhow::Result;
use std::path::{Path, PathBuf};

/// User-selectable content categories for pack export.
#[derive(Debug, Clone)]
pub struct ExportIncludes {
    pub mods: bool,
    pub resourcepacks: bool,
    pub shaderpacks: bool,
    pub datapacks: bool,
    pub config: bool,
    pub options: bool,
    pub saves: bool,
}

impl Default for ExportIncludes {
    fn default() -> Self {
        Self {
            mods: true,
            resourcepacks: true,
            shaderpacks: true,
            datapacks: true,
            config: true,
            options: true,
            saves: false,
        }
    }
}

impl ExportIncludes {
    pub fn from_ids(ids: &[String]) -> Self {
        let has = |id: &str| ids.iter().any(|x| x.eq_ignore_ascii_case(id));
        // Empty list → keep defaults (everything except saves).
        if ids.is_empty() {
            return Self::default();
        }
        Self {
            mods: has("mods"),
            resourcepacks: has("resourcepacks"),
            shaderpacks: has("shaderpacks"),
            datapacks: has("datapacks"),
            config: has("config"),
            options: has("options"),
            saves: has("saves"),
        }
    }

    pub fn allows_top(&self, top: &str) -> bool {
        match top {
            "mods" => self.mods,
            "resourcepacks" => self.resourcepacks,
            "shaderpacks" => self.shaderpacks,
            "datapacks" => self.datapacks,
            "config" | "configs" | "defaultconfigs" | "kubejs" | "scripts" | "patchouli_books" => {
                self.config
            }
            "options.txt" => self.options,
            "saves" => self.saves,
            "icon.png" => true,
            _ => false,
        }
    }
}

/// One file shown under a content category.
#[derive(Debug, Clone)]
pub struct PackContentFile {
    pub path: String,
    pub name: String,
    pub size_bytes: u64,
    pub icon_url: Option<String>,
    pub title: Option<String>,
}

/// One content category shown in export/import previews.
#[derive(Debug, Clone)]
pub struct PackContentCategory {
    pub id: String,
    pub label: String,
    pub file_count: u32,
    pub total_bytes: u64,
    pub files: Vec<PackContentFile>,
}

/// Paths that should never be bundled into an exported pack (unless explicitly allowed).
pub fn should_skip_export_path(rel: &str, includes: &ExportIncludes) -> bool {
    let lower = rel.to_lowercase();
    if lower.starts_with("saves/") {
        return !includes.saves;
    }
    lower.starts_with("logs/")
        || lower.starts_with("crash-reports/")
        || lower.starts_with("screenshots/")
        || lower.contains("/.cache/")
        || lower.ends_with(".log")
        || lower == "usercache.json"
        || lower == "usernamecache.json"
        || lower == "launcher_profiles.json"
        || lower.starts_with("versions/")
        || lower.starts_with("libraries/")
        || lower.starts_with("assets/")
}

fn category_for_top(top: &str) -> Option<(&'static str, &'static str)> {
    match top {
        "mods" => Some(("mods", "模组")),
        "resourcepacks" => Some(("resourcepacks", "资源包")),
        "shaderpacks" => Some(("shaderpacks", "光影包")),
        "datapacks" => Some(("datapacks", "数据包")),
        "config" | "configs" | "defaultconfigs" | "kubejs" | "scripts" | "patchouli_books" => {
            Some(("config", "配置与脚本"))
        }
        "options.txt" => Some(("options", "游戏选项")),
        "saves" => Some(("saves", "存档")),
        _ => None,
    }
}

/// Summarize exportable content under an instance directory.
pub fn summarize_export_content(instance_dir: &Path) -> Result<Vec<PackContentCategory>> {
    let includes = ExportIncludes {
        saves: true, // include saves in the summary so UI can offer the toggle
        ..ExportIncludes::default()
    };
    let files = collect_pack_content_files(instance_dir, &includes)?;
    summarize_files(instance_dir, &files)
}

fn summarize_files(root: &Path, files: &[PathBuf]) -> Result<Vec<PackContentCategory>> {
    use std::collections::BTreeMap;
    let mut map: BTreeMap<&'static str, PackContentCategory> = BTreeMap::new();

    let push = |map: &mut BTreeMap<&'static str, PackContentCategory>,
                id: &'static str,
                label: &'static str,
                rel: String,
                size: u64| {
        let name = rel
            .rsplit('/')
            .next()
            .unwrap_or(rel.as_str())
            .to_string();
        let entry = map.entry(id).or_insert_with(|| PackContentCategory {
            id: id.into(),
            label: label.into(),
            file_count: 0,
            total_bytes: 0,
            files: Vec::new(),
        });
        entry.file_count += 1;
        entry.total_bytes += size;
        entry.files.push(PackContentFile {
            path: rel,
            name,
            size_bytes: size,
            icon_url: None,
            title: None,
        });
    };

    for path in files {
        if !path.is_file() {
            continue;
        }
        let Ok(rel) = path.strip_prefix(root) else {
            continue;
        };
        let rel = rel.to_string_lossy().replace('\\', "/");
        let size = path.metadata().map(|m| m.len()).unwrap_or(0);
        let top = rel.split('/').next().unwrap_or(&rel);
        if let Some((id, label)) = category_for_top(top) {
            push(&mut map, id, label, rel, size);
        } else if rel == "options.txt" {
            push(&mut map, "options", "游戏选项", rel, size);
        }
    }

    // Stable UI order
    let order = [
        "mods",
        "resourcepacks",
        "shaderpacks",
        "datapacks",
        "config",
        "options",
        "saves",
    ];
    let mut out = Vec::new();
    for id in order {
        if let Some(mut cat) = map.remove(id) {
            cat.files.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
            out.push(cat);
        }
    }
    for mut cat in map.into_values() {
        cat.files.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        out.push(cat);
    }
    Ok(out)
}

/// Apply Modrinth/content metadata (icons, titles) onto summarized files.
pub fn enrich_categories_with_content(
    categories: &mut [PackContentCategory],
    content: &[crate::state::db::ContentEntry],
) {
    use std::collections::HashMap;
    let by_path: HashMap<String, &crate::state::db::ContentEntry> = content
        .iter()
        .map(|e| (e.relative_path.replace('\\', "/"), e))
        .collect();
    for cat in categories.iter_mut() {
        for file in cat.files.iter_mut() {
            if let Some(meta) = by_path.get(&file.path) {
                if file.icon_url.is_none() {
                    file.icon_url = meta.project_icon_url.clone();
                }
                if file.title.is_none() {
                    file.title = meta.project_title.clone();
                }
            }
        }
    }
}

/// Collect instance files suitable for offline pack export (MMC / MCBBS).
pub fn collect_pack_content_files(
    instance_dir: &Path,
    includes: &ExportIncludes,
) -> Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    collect_pack_content_files_inner(instance_dir, instance_dir, includes, &mut out)?;
    if includes.options {
        let p = instance_dir.join("options.txt");
        if p.is_file() && !out.iter().any(|x| x == &p) {
            out.push(p);
        }
    }
    let icon = instance_dir.join("icon.png");
    if icon.is_file() && !out.iter().any(|x| x == &icon) {
        out.push(icon);
    }
    Ok(out)
}

fn collect_pack_content_files_inner(
    root: &Path,
    current: &Path,
    includes: &ExportIncludes,
    out: &mut Vec<PathBuf>,
) -> Result<()> {
    if !current.is_dir() {
        return Ok(());
    }
    for entry in std::fs::read_dir(current)? {
        let entry = entry?;
        let path = entry.path();
        let Ok(rel) = path.strip_prefix(root) else {
            continue;
        };
        let rel = rel.to_string_lossy().replace('\\', "/");
        if should_skip_export_path(&rel, includes) {
            continue;
        }
        if path.is_dir() {
            let top = rel.split('/').next().unwrap_or("");
            if includes.allows_top(top) || rel.is_empty() {
                collect_pack_content_files_inner(root, &path, includes, out)?;
            }
        } else {
            let top = rel.split('/').next().unwrap_or("");
            if includes.allows_top(top) || (includes.options && rel == "options.txt") || rel == "icon.png"
            {
                out.push(path);
            }
        }
    }
    Ok(())
}

/// Collect override candidates for mrpack (skip files already listed as remote downloads).
pub fn collect_override_candidates(
    root: &Path,
    current: &Path,
    skip: &std::collections::HashSet<String>,
    includes: &ExportIncludes,
    out: &mut Vec<PathBuf>,
) -> Result<()> {
    if !current.is_dir() {
        return Ok(());
    }
    for entry in std::fs::read_dir(current)? {
        let entry = entry?;
        let path = entry.path();
        let Ok(rel) = path.strip_prefix(root) else {
            continue;
        };
        let rel = rel.to_string_lossy().replace('\\', "/");
        if should_skip_export_path(&rel, includes) {
            continue;
        }
        if path.is_dir() {
            let top = rel.split('/').next().unwrap_or("");
            if includes.allows_top(top) || rel.is_empty() {
                collect_override_candidates(root, &path, skip, includes, out)?;
            }
        } else if !skip.contains(&rel) {
            let top = rel.split('/').next().unwrap_or("");
            if includes.allows_top(top)
                || (includes.options && rel == "options.txt")
                || rel == "icon.png"
            {
                out.push(path);
            }
        }
    }
    Ok(())
}

/// Whether a relative content path should be included under the given filter.
pub fn relative_path_allowed(
    rel: &str,
    includes: &ExportIncludes,
    path_filter: Option<&std::collections::HashSet<String>>,
) -> bool {
    let rel = rel.replace('\\', "/");
    if let Some(filter) = path_filter {
        if !filter.contains(&rel) {
            return false;
        }
    }
    if should_skip_export_path(&rel, includes) {
        return false;
    }
    let top = rel.split('/').next().unwrap_or(&rel);
    includes.allows_top(top) || (includes.options && rel == "options.txt") || rel == "icon.png"
}

/// Filter collected absolute paths by optional relative-path allowlist.
pub fn filter_paths_by_rel(
    root: &Path,
    files: Vec<PathBuf>,
    path_filter: Option<&std::collections::HashSet<String>>,
) -> Vec<PathBuf> {
    let Some(filter) = path_filter else {
        return files;
    };
    files
        .into_iter()
        .filter(|path| {
            path.strip_prefix(root)
                .ok()
                .map(|rel| filter.contains(&rel.to_string_lossy().replace('\\', "/")))
                .unwrap_or(false)
        })
        .collect()
}

/// Sanitize a name for use as a zip folder / file stem.
pub fn sanitize_pack_name(name: &str) -> String {
    let mut s: String = name
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    s = s.trim().trim_matches('.').to_string();
    if s.is_empty() {
        "Instance".into()
    } else {
        s
    }
}
