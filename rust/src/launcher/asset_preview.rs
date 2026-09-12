use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};
use zip::ZipArchive;

use crate::meta::minecraft::AssetsIndex;
use crate::state::models::ModLoader;

use super::dirs;
use super::download::client_jar_path;
use super::manifest;

const CACHE_SUBDIR: &str = "cache/asset_preview";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AssetPreviewEntry {
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

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AssetPreviewCatalog {
    pub fingerprint: String,
    pub scanned_at: String,
    pub entries: Vec<AssetPreviewEntry>,
}

#[derive(Clone, Debug)]
pub struct ModelFace {
    pub texture_index: usize,
    pub u0: f64,
    pub v0: f64,
    pub u1: f64,
    pub v1: f64,
}

#[derive(Clone, Debug)]
pub struct ModelElement {
    pub from: [f64; 3],
    pub to: [f64; 3],
    pub faces: HashMap<String, ModelFace>,
}

#[derive(Clone, Debug)]
pub struct ResolvedAssetPreview {
    pub entry_id: String,
    pub preview_kind: String,
    pub elements: Vec<ModelElement>,
    pub textures: Vec<Vec<u8>>,
    pub gui_rotation: Option<[f64; 3]>,
    pub gui_scale: Option<f64>,
}

#[derive(Clone)]
struct ZipSource {
    id: String,
    label: String,
    kind: String,
    path: PathBuf,
    priority: i32,
}

#[derive(Clone, Serialize, Deserialize)]
struct FingerprintState {
    game_version: String,
    version_jar_id: String,
    client_jar: String,
    mods: Vec<String>,
    resourcepacks: Vec<String>,
}

fn cache_root(resource_dir: &str, instance_id: &str) -> PathBuf {
    PathBuf::from(resource_dir)
        .join(CACHE_SUBDIR)
        .join(instance_id)
}

fn resolve_vanilla_jar_path(
    resource_dir: &str,
    game_version: &str,
    version_jar_id: &str,
) -> PathBuf {
    for candidate in [
        client_jar_path(resource_dir, version_jar_id),
        client_jar_path(resource_dir, game_version),
    ] {
        if candidate.exists() {
            return candidate;
        }
    }
    client_jar_path(resource_dir, version_jar_id)
}

struct AssetArchives<'a> {
    primary: &'a Path,
    vanilla: Option<&'a Path>,
}

impl AssetArchives<'_> {
    fn read_text(&self, asset_path: &str) -> Result<String> {
        read_zip_text(self.primary, asset_path).or_else(|primary_err| {
            if let Some(vanilla) = self.vanilla {
                if vanilla != self.primary && asset_path.starts_with("assets/minecraft/") {
                    return read_zip_text(vanilla, asset_path);
                }
            }
            Err(primary_err)
        })
    }

    fn read_bytes(&self, asset_path: &str) -> Result<Vec<u8>> {
        read_zip_bytes(self.primary, asset_path).or_else(|primary_err| {
            if let Some(vanilla) = self.vanilla {
                if vanilla != self.primary && asset_path.starts_with("assets/minecraft/") {
                    return read_zip_bytes(vanilla, asset_path);
                }
            }
            Err(primary_err)
        })
    }
}

pub async fn scan_instance_assets(instance_id: &str, force: bool) -> Result<AssetPreviewCatalog> {
    let state = crate::state::try_state()?;
    let pool = &state.pool;
    let resource = crate::state::resource_dir().await?;
    let instance = crate::state::db::get_instance(pool, instance_id)
        .await
        .with_context(|| format!("instance {instance_id}"))?;

    let loader = ModLoader::parse(&instance.loader);
    let version_jar_id = manifest::version_jar_id_for_instance(
        &instance.game_version,
        &loader,
        instance.loader_version.as_deref(),
    );
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let client_jar = resolve_vanilla_jar_path(&resource, &instance.game_version, &version_jar_id);

    let fp_state = build_fingerprint_state(
        &instance.game_version,
        &version_jar_id,
        &client_jar,
        &instance_dir,
    )
    .await?;
    let fingerprint = hash_fingerprint(&fp_state);
    let cache_dir = cache_root(&resource, instance_id);
    let catalog_path = cache_dir.join("catalog.json");
    let fp_path = cache_dir.join("fingerprint.txt");

    if !force && catalog_path.exists() && fp_path.exists() {
        let cached_fp = tokio::fs::read_to_string(&fp_path).await?;
        if cached_fp.trim() == fingerprint {
            let bytes = tokio::fs::read(&catalog_path).await?;
            if let Ok(catalog) = serde_json::from_slice::<AssetPreviewCatalog>(&bytes) {
                return Ok(catalog);
            }
        }
    }

    let fp_for_cache = fingerprint.clone();
    let catalog = tokio::task::spawn_blocking(move || {
        scan_blocking(
            &resource,
            &instance.game_version,
            &version_jar_id,
            &client_jar,
            &instance_dir,
            &fingerprint,
        )
    })
    .await??;

    tokio::fs::create_dir_all(&cache_dir).await.ok();
    tokio::fs::write(&fp_path, &fp_for_cache).await.ok();
    let json = serde_json::to_vec_pretty(&catalog)?;
    tokio::fs::write(&catalog_path, json).await.ok();
    Ok(catalog)
}

pub async fn resolve_asset_preview(
    instance_id: &str,
    entry_id: &str,
) -> Result<ResolvedAssetPreview> {
    let state = crate::state::try_state()?;
    let pool = &state.pool;
    let resource = crate::state::resource_dir().await?;
    let instance = crate::state::db::get_instance(pool, instance_id).await?;

    let catalog = scan_instance_assets(instance_id, false).await?;
    let entry = catalog
        .entries
        .iter()
        .find(|e| e.id == entry_id)
        .ok_or_else(|| anyhow!("unknown asset entry: {entry_id}"))?
        .clone();

    let loader = ModLoader::parse(&instance.loader);
    let version_jar_id = manifest::version_jar_id_for_instance(
        &instance.game_version,
        &loader,
        instance.loader_version.as_deref(),
    );
    let instance_dir = dirs::instance_dir(&resource, &instance.path);
    let client_jar = client_jar_path(&resource, &version_jar_id);

    let texture_cache_dir = cache_root(&resource, instance_id).join("textures");
    tokio::fs::create_dir_all(&texture_cache_dir).await.ok();

    let resolved = tokio::task::spawn_blocking(move || {
        resolve_blocking(
            &resource,
            &instance.game_version,
            &version_jar_id,
            &client_jar,
            &instance_dir,
            &entry,
            &texture_cache_dir,
        )
    })
    .await??;

    Ok(resolved)
}

async fn build_fingerprint_state(
    game_version: &str,
    version_jar_id: &str,
    client_jar: &Path,
    instance_dir: &Path,
) -> Result<FingerprintState> {
    let client_jar_sig = file_signature(client_jar).await?;
    let mut mods = Vec::new();
    let mods_dir = instance_dir.join("mods");
    if mods_dir.exists() {
        let mut entries = tokio::fs::read_dir(&mods_dir).await?;
        while let Some(entry) = entries.next_entry().await? {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jar") {
                continue;
            }
            if path
                .file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.ends_with(".jar.disabled"))
                .unwrap_or(false)
            {
                continue;
            }
            mods.push(format!(
                "{}:{}",
                path.file_name().unwrap_or_default().to_string_lossy(),
                file_signature(&path).await?
            ));
        }
    }
    mods.sort();

    let mut resourcepacks = Vec::new();
    let packs_dir = instance_dir.join("resourcepacks");
    if packs_dir.exists() {
        let mut entries = tokio::fs::read_dir(&packs_dir).await?;
        while let Some(entry) = entries.next_entry().await? {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            resourcepacks.push(format!(
                "{}:{}",
                path.file_name().unwrap_or_default().to_string_lossy(),
                file_signature(&path).await?
            ));
        }
    }
    resourcepacks.sort();

    Ok(FingerprintState {
        game_version: game_version.to_string(),
        version_jar_id: version_jar_id.to_string(),
        client_jar: client_jar_sig,
        mods,
        resourcepacks,
    })
}

async fn file_signature(path: &Path) -> Result<String> {
    let meta = tokio::fs::metadata(path).await?;
    let modified = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    Ok(format!("{}:{}", meta.len(), modified))
}

fn hash_fingerprint(state: &FingerprintState) -> String {
    let json = serde_json::to_string(state).unwrap_or_default();
    let digest = Sha256::digest(json.as_bytes());
    hex::encode(digest)
}

fn scan_blocking(
    _resource_dir: &str,
    _game_version: &str,
    _version_jar_id: &str,
    client_jar: &Path,
    instance_dir: &Path,
    fingerprint: &str,
) -> Result<AssetPreviewCatalog> {
    let mut sources = Vec::new();
    if client_jar.exists() {
        sources.push(ZipSource {
            id: "vanilla".into(),
            label: format!("游戏本体 · {_game_version}"),
            kind: "vanilla".into(),
            path: client_jar.to_path_buf(),
            priority: 0,
        });
    }

    let mods_dir = instance_dir.join("mods");
    if mods_dir.exists() {
        for entry in std::fs::read_dir(&mods_dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jar") {
                continue;
            }
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("mod.jar");
            if name.ends_with(".jar.disabled") {
                continue;
            }
            sources.push(ZipSource {
                id: format!("mod:{name}"),
                label: format!("Mod · {name}"),
                kind: "mod".into(),
                path,
                priority: 10,
            });
        }
    }

    let packs_dir = instance_dir.join("resourcepacks");
    if packs_dir.exists() {
        for entry in std::fs::read_dir(&packs_dir)? {
            let entry = entry?;
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("pack.zip");
            sources.push(ZipSource {
                id: format!("pack:{name}"),
                label: format!("资源包 · {name}"),
                kind: "resourcepack".into(),
                path,
                priority: 20,
            });
        }
    }

    let mut entries = Vec::new();
    let mut seen_models: HashSet<String> = HashSet::new();
    let mut seen_textures: HashSet<String> = HashSet::new();

    for source in &sources {
        let zip_entries = scan_zip_source(source)?;
        for e in zip_entries {
            if let Some(ref model_path) = e.model_path {
                let key = format!("{}|{}", source.id, model_path);
                if seen_models.insert(key) {
                    entries.push(e);
                }
            } else if let Some(ref texture_path) = e.texture_path {
                let key = format!("{}|{}", source.id, texture_path);
                if seen_textures.insert(key) {
                    entries.push(e);
                }
            }
        }
    }

    entries.sort_by(|a, b| {
        a.namespace
            .cmp(&b.namespace)
            .then(a.category.cmp(&b.category))
            .then(a.name.cmp(&b.name))
            .then(a.source_kind.cmp(&b.source_kind))
    });

    Ok(AssetPreviewCatalog {
        fingerprint: fingerprint.to_string(),
        scanned_at: chrono::Utc::now().to_rfc3339(),
        entries,
    })
}

fn scan_zip_source(source: &ZipSource) -> Result<Vec<AssetPreviewEntry>> {
    let file = std::fs::File::open(&source.path)?;
    let mut archive = ZipArchive::new(file)?;
    let mut model_paths: HashSet<String> = HashSet::new();
    let mut raw_paths: Vec<String> = Vec::new();

    for i in 0..archive.len() {
        let name = archive.by_index(i)?.name().replace('\\', "/");
        if name.starts_with("assets/") {
            raw_paths.push(name);
        }
    }

    for name in &raw_paths {
        let parts: Vec<&str> = name.split('/').collect();
        if parts.len() >= 5 && parts[2] == "models" && name.ends_with(".json") {
            model_paths.insert(name.clone());
        }
    }

    let mut out = Vec::new();
    for name in raw_paths {
        let parts: Vec<&str> = name.split('/').collect();
        if parts.len() < 4 {
            continue;
        }
        let namespace = parts[1].to_string();
        if namespace == "realms" || namespace.starts_with('.') {
            continue;
        }

        if parts[2] == "models" && name.ends_with(".json") && parts.len() >= 5 {
            let category = parts[3].to_string();
            if category != "item" && category != "block" {
                continue;
            }
            let model_name = name
                .trim_end_matches(".json")
                .rsplit('/')
                .next()
                .unwrap_or("unknown")
                .to_string();
            let model_path = name.clone();
            let texture_path = Some(format!(
                "assets/{namespace}/textures/{category}/{model_name}.png"
            ));
            out.push(AssetPreviewEntry {
                id: format!("{}:{}", source.id, model_path),
                namespace,
                name: model_name,
                category,
                model_path: Some(model_path),
                texture_path,
                source_id: source.id.clone(),
                source_label: source.label.clone(),
                source_kind: source.kind.clone(),
            });
            continue;
        }

        if parts[2] == "textures" && name.ends_with(".png") {
            let tex_category = parts[3].to_string();
            if tex_category != "item" && tex_category != "block" {
                continue;
            }
            let tex_name = name
                .trim_end_matches(".png")
                .rsplit('/')
                .next()
                .unwrap_or("unknown")
                .to_string();
            let texture_path = name.clone();
            let model_path = format!("assets/{namespace}/models/{tex_category}/{tex_name}.json");
            if model_paths.contains(&model_path) {
                continue;
            }
            out.push(AssetPreviewEntry {
                id: format!("{}:{}", source.id, texture_path),
                namespace,
                name: tex_name,
                category: tex_category,
                model_path: None,
                texture_path: Some(texture_path),
                source_id: source.id.clone(),
                source_label: source.label.clone(),
                source_kind: source.kind.clone(),
            });
        }
    }

    Ok(out)
}

fn resolve_blocking(
    resource_dir: &str,
    game_version: &str,
    version_jar_id: &str,
    client_jar: &Path,
    instance_dir: &Path,
    entry: &AssetPreviewEntry,
    texture_cache_dir: &Path,
) -> Result<ResolvedAssetPreview> {
    let source_path = resolve_source_path(instance_dir, client_jar, &entry.source_id)?;
    let vanilla_jar = resolve_vanilla_jar_path(resource_dir, game_version, version_jar_id);
    let archives = AssetArchives {
        primary: &source_path,
        vanilla: if vanilla_jar.exists() {
            Some(vanilla_jar.as_path())
        } else {
            None
        },
    };
    let asset_index = load_asset_index(resource_dir, version_jar_id)
        .or_else(|_| load_asset_index(resource_dir, game_version))
        .ok();

    if let Some(model_path) = &entry.model_path {
        let model_json = archives
            .read_text(model_path)
            .with_context(|| format!("读取模型失败: {model_path}"))?;
        let default_texture = entry.texture_path.as_deref();
        let resolved = resolve_model_json(
            &archives,
            &entry.namespace,
            &model_json,
            default_texture,
            asset_index.as_ref(),
            resource_dir,
            texture_cache_dir,
            &entry.id,
        )?;
        return Ok(ResolvedAssetPreview {
            entry_id: entry.id.clone(),
            preview_kind: resolved.preview_kind,
            elements: resolved.elements,
            textures: resolved.textures,
            gui_rotation: resolved.gui_rotation,
            gui_scale: resolved.gui_scale,
        });
    }

    if let Some(texture_path) = entry.texture_path.as_ref() {
        let png = read_texture_bytes(
            &archives,
            texture_path,
            &entry.namespace,
            asset_index.as_ref(),
            resource_dir,
            texture_cache_dir,
            &entry.id,
            "all",
        )?;
        let elements = flat_item_element();
        return Ok(ResolvedAssetPreview {
            entry_id: entry.id.clone(),
            preview_kind: "item_flat".into(),
            elements,
            textures: vec![png],
            gui_rotation: Some([30.0, 45.0, 0.0]),
            gui_scale: Some(0.9),
        });
    }

    Err(anyhow!("entry has no model or texture"))
}

fn resolve_source_path(instance_dir: &Path, client_jar: &Path, source_id: &str) -> Result<PathBuf> {
    if source_id == "vanilla" {
        return Ok(client_jar.to_path_buf());
    }
    if let Some(name) = source_id.strip_prefix("mod:") {
        return Ok(instance_dir.join("mods").join(name));
    }
    if let Some(name) = source_id.strip_prefix("pack:") {
        return Ok(instance_dir.join("resourcepacks").join(name));
    }
    Err(anyhow!("unknown source id: {source_id}"))
}

struct ResolvedModelInternal {
    preview_kind: String,
    elements: Vec<ModelElement>,
    textures: Vec<Vec<u8>>,
    gui_rotation: Option<[f64; 3]>,
    gui_scale: Option<f64>,
}

fn resolve_model_json(
    archives: &AssetArchives<'_>,
    namespace: &str,
    model_json: &str,
    default_texture_path: Option<&str>,
    asset_index: Option<&AssetsIndex>,
    resource_dir: &str,
    texture_cache_dir: &Path,
    entry_id: &str,
) -> Result<ResolvedModelInternal> {
    let root: serde_json::Value = serde_json::from_str(model_json)?;
    let parent_name = root
        .get("parent")
        .and_then(|v| v.as_str())
        .map(normalize_parent);

    let mut textures_map: HashMap<String, String> = HashMap::new();
    if let Some(tex) = root.get("textures").and_then(|v| v.as_object()) {
        for (k, v) in tex {
            if let Some(s) = v.as_str() {
                textures_map.insert(k.clone(), s.to_string());
            }
        }
    }
    if textures_map.is_empty() {
        if let Some(path) = default_texture_path {
            let tex_ref = path
                .strip_prefix("assets/")
                .and_then(|p| p.strip_prefix(&format!("{namespace}/textures/")))
                .map(|p| p.trim_end_matches(".png"))
                .unwrap_or("item/unknown");
            textures_map.insert("layer0".into(), format!("{namespace}:{tex_ref}"));
            textures_map.insert("all".into(), format!("{namespace}:{tex_ref}"));
        }
    }

    let mut elements: Vec<serde_json::Value> = Vec::new();
    if let Some(arr) = root.get("elements").and_then(|v| v.as_array()) {
        elements.extend(arr.iter().cloned());
    }

    let mut gui_rotation = None;
    let mut gui_scale = None;
    if let Some(gui) = root.get("display").and_then(|d| d.get("gui")) {
        if let Some(rot) = gui.get("rotation").and_then(|v| v.as_array()) {
            if rot.len() == 3 {
                gui_rotation = Some([
                    rot[0].as_f64().unwrap_or(0.0),
                    rot[1].as_f64().unwrap_or(0.0),
                    rot[2].as_f64().unwrap_or(0.0),
                ]);
            }
        }
        if let Some(scale) = gui.get("scale").and_then(|v| v.as_array()) {
            if !scale.is_empty() {
                gui_scale = Some(scale[0].as_f64().unwrap_or(1.0));
            }
        }
    }

    let mut preview_kind = "block".to_string();
    if let Some(ref parent) = parent_name {
        if parent.contains("item/generated") || parent.contains("item/handheld") {
            preview_kind = "item_block".into();
        }
        if elements.is_empty() {
            inherit_parent_model(
                archives,
                namespace,
                parent,
                &mut textures_map,
                &mut elements,
                &mut preview_kind,
            )?;
        }
    }

    if elements.is_empty() && preview_kind.contains("item") {
        preview_kind = "item_flat".into();
        elements = vec![serde_json::to_value(flat_item_element_json())?];
    }

    if elements.is_empty() {
        elements.push(serde_json::json!({
            "from": [0, 0, 0],
            "to": [16, 16, 16],
            "faces": {
                "north": {"uv": [0, 0, 16, 16], "texture": "#all"},
                "south": {"uv": [0, 0, 16, 16], "texture": "#all"},
                "east": {"uv": [0, 0, 16, 16], "texture": "#all"},
                "west": {"uv": [0, 0, 16, 16], "texture": "#all"},
                "up": {"uv": [0, 0, 16, 16], "texture": "#all"},
                "down": {"uv": [0, 0, 16, 16], "texture": "#all"}
            }
        }));
        if textures_map.is_empty() {
            textures_map.insert("all".into(), "minecraft:block/stone".into());
        }
    }

    let mut texture_bytes: Vec<Vec<u8>> = Vec::new();
    let mut texture_index_map: HashMap<String, usize> = HashMap::new();

    let parsed_elements = parse_elements(
        &elements,
        &textures_map,
        archives,
        namespace,
        asset_index,
        resource_dir,
        texture_cache_dir,
        entry_id,
        &mut texture_bytes,
        &mut texture_index_map,
    )?;

    Ok(ResolvedModelInternal {
        preview_kind,
        elements: parsed_elements,
        textures: texture_bytes,
        gui_rotation,
        gui_scale,
    })
}

fn inherit_parent_model(
    archives: &AssetArchives<'_>,
    namespace: &str,
    parent: &str,
    textures_map: &mut HashMap<String, String>,
    elements: &mut Vec<serde_json::Value>,
    preview_kind: &mut String,
) -> Result<()> {
    let chain = vec![
        parent.to_string(),
        "minecraft:block/cube_all".into(),
        "minecraft:block/cube".into(),
    ];

    for parent_ref in chain {
        let parent_path = parent_to_asset_path(&parent_ref);
        let json = archives
            .read_text(&parent_path)
            .or_else(|_| read_builtin_parent_json(&parent_ref))?;
        let value: serde_json::Value = serde_json::from_str(&json)?;

        if let Some(tex) = value.get("textures").and_then(|v| v.as_object()) {
            for (k, v) in tex {
                if let Some(s) = v.as_str() {
                    textures_map
                        .entry(k.clone())
                        .or_insert_with(|| resolve_texture_ref(s, namespace));
                }
            }
        }

        if let Some(arr) = value.get("elements").and_then(|v| v.as_array()) {
            if !arr.is_empty() {
                elements.extend(arr.iter().cloned());
                break;
            }
        }

        if parent_ref.contains("item/generated") {
            *preview_kind = "item_flat".into();
        }
    }

    Ok(())
}

fn parent_to_asset_path(parent: &str) -> String {
    let normalized = normalize_parent(parent);
    if normalized.contains(':') {
        let (ns, path) = normalized.split_once(':').unwrap();
        format!("assets/{ns}/models/{path}.json")
    } else {
        format!("assets/minecraft/models/{normalized}.json")
    }
}

fn normalize_parent(parent: &str) -> String {
    if parent.contains(':') {
        parent.to_string()
    } else {
        format!("minecraft:{parent}")
    }
}

fn read_builtin_parent_json(parent: &str) -> Result<String> {
    let normalized = normalize_parent(parent);
    match normalized.as_str() {
        "minecraft:block/cube_all" => Ok(serde_json::to_string(&serde_json::json!({
            "textures": {
                "particle": "#all",
                "down": "#all",
                "up": "#all",
                "north": "#all",
                "east": "#all",
                "south": "#all",
                "west": "#all"
            },
            "elements": [{
                "from": [0, 0, 0],
                "to": [16, 16, 16],
                "faces": {
                    "down": {"uv": [0, 0, 16, 16], "texture": "#down"},
                    "up": {"uv": [0, 0, 16, 16], "texture": "#up"},
                    "north": {"uv": [0, 0, 16, 16], "texture": "#north"},
                    "south": {"uv": [0, 0, 16, 16], "texture": "#south"},
                    "west": {"uv": [0, 0, 16, 16], "texture": "#west"},
                    "east": {"uv": [0, 0, 16, 16], "texture": "#east"}
                }
            }]
        }))?),
        "minecraft:item/generated" | "minecraft:item/handheld" => {
            Ok(r#"{"parent":"minecraft:item/generated"}"#.into())
        }
        _ => Err(anyhow!("builtin parent not found: {normalized}")),
    }
}

fn resolve_texture_ref(reference: &str, namespace: &str) -> String {
    if reference.starts_with('#') {
        return reference.to_string();
    }
    if reference.contains(':') {
        reference.to_string()
    } else {
        format!("{namespace}:{reference}")
    }
}

fn parse_elements(
    elements: &[serde_json::Value],
    textures_map: &HashMap<String, String>,
    archives: &AssetArchives<'_>,
    namespace: &str,
    asset_index: Option<&AssetsIndex>,
    resource_dir: &str,
    texture_cache_dir: &Path,
    entry_id: &str,
    texture_bytes: &mut Vec<Vec<u8>>,
    texture_index_map: &mut HashMap<String, usize>,
) -> Result<Vec<ModelElement>> {
    let mut out = Vec::new();
    for element in elements {
        let from = parse_vec3(element.get("from"), [0.0, 0.0, 0.0]);
        let to = parse_vec3(element.get("to"), [16.0, 16.0, 16.0]);
        let mut faces = HashMap::new();
        if let Some(face_obj) = element.get("faces").and_then(|v| v.as_object()) {
            for (dir, face) in face_obj {
                let texture_key = face
                    .get("texture")
                    .and_then(|v| v.as_str())
                    .unwrap_or("#all");
                let resolved_ref = resolve_face_texture(texture_key, textures_map, namespace);
                let tex_idx = load_texture_index(
                    &resolved_ref,
                    archives,
                    namespace,
                    asset_index,
                    resource_dir,
                    texture_cache_dir,
                    entry_id,
                    texture_bytes,
                    texture_index_map,
                )?;
                let uv = face
                    .get("uv")
                    .and_then(|v| v.as_array())
                    .map(|a| {
                        [
                            a.first().and_then(|x| x.as_f64()).unwrap_or(0.0),
                            a.get(1).and_then(|x| x.as_f64()).unwrap_or(0.0),
                            a.get(2).and_then(|x| x.as_f64()).unwrap_or(16.0),
                            a.get(3).and_then(|x| x.as_f64()).unwrap_or(16.0),
                        ]
                    })
                    .unwrap_or([0.0, 0.0, 16.0, 16.0]);
                faces.insert(
                    dir.clone(),
                    ModelFace {
                        texture_index: tex_idx,
                        u0: uv[0],
                        v0: uv[1],
                        u1: uv[2],
                        v1: uv[3],
                    },
                );
            }
        }
        out.push(ModelElement { from, to, faces });
    }
    Ok(out)
}

fn resolve_face_texture(
    key: &str,
    textures_map: &HashMap<String, String>,
    namespace: &str,
) -> String {
    if key.starts_with('#') {
        let var_name = &key[1..];
        if let Some(resolved) = textures_map.get(var_name) {
            return resolve_texture_ref(resolved, namespace);
        }
    }
    resolve_texture_ref(key, namespace)
}

fn load_texture_index(
    texture_ref: &str,
    archives: &AssetArchives<'_>,
    namespace: &str,
    asset_index: Option<&AssetsIndex>,
    resource_dir: &str,
    texture_cache_dir: &Path,
    entry_id: &str,
    texture_bytes: &mut Vec<Vec<u8>>,
    texture_index_map: &mut HashMap<String, usize>,
) -> Result<usize> {
    let key = texture_ref.to_string();
    if let Some(&idx) = texture_index_map.get(&key) {
        return Ok(idx);
    }
    let png = read_texture_by_ref(
        texture_ref,
        archives,
        namespace,
        asset_index,
        resource_dir,
        texture_cache_dir,
        entry_id,
    )?;
    let idx = texture_bytes.len();
    texture_bytes.push(png);
    texture_index_map.insert(key, idx);
    Ok(idx)
}

fn read_texture_by_ref(
    texture_ref: &str,
    archives: &AssetArchives<'_>,
    fallback_namespace: &str,
    asset_index: Option<&AssetsIndex>,
    resource_dir: &str,
    texture_cache_dir: &Path,
    entry_id: &str,
) -> Result<Vec<u8>> {
    let (ns, path) = if let Some((a, b)) = texture_ref.split_once(':') {
        (a.to_string(), b.to_string())
    } else {
        (fallback_namespace.to_string(), texture_ref.to_string())
    };
    let asset_path = format!("assets/{ns}/textures/{path}.png");
    read_texture_bytes(
        archives,
        &asset_path,
        &ns,
        asset_index,
        resource_dir,
        texture_cache_dir,
        entry_id,
        &path,
    )
}

fn read_texture_bytes(
    archives: &AssetArchives<'_>,
    asset_path: &str,
    namespace: &str,
    asset_index: Option<&AssetsIndex>,
    resource_dir: &str,
    texture_cache_dir: &Path,
    entry_id: &str,
    cache_suffix: &str,
) -> Result<Vec<u8>> {
    let cache_key = format!("{entry_id}_{cache_suffix}");
    let cache_file = texture_cache_dir.join(format!("{cache_key}.png"));
    if cache_file.exists() {
        return Ok(std::fs::read(&cache_file)?);
    }

    if let Ok(bytes) = archives.read_bytes(asset_path) {
        std::fs::write(&cache_file, &bytes).ok();
        return Ok(bytes);
    }

    if let Some(index) = asset_index {
        let index_key = asset_path
            .strip_prefix("assets/")
            .unwrap_or(asset_path)
            .to_string();
        if let Some(asset) = index.objects.get(&index_key) {
            let prefix = &asset.hash[..2.min(asset.hash.len())];
            let object_path = dirs::assets(resource_dir)
                .join("objects")
                .join(prefix)
                .join(&asset.hash);
            if object_path.exists() {
                let bytes = std::fs::read(&object_path)?;
                std::fs::write(&cache_file, &bytes).ok();
                return Ok(bytes);
            }
        }
    }

    // Fallback placeholder 16x16 magenta
    let placeholder = vec![
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 16, 0, 0, 0, 16, 8,
        6, 0, 0, 0, 31, 243, 255, 97, 0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192,
        240, 31, 0, 4, 193, 1, 31, 210, 68, 205, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    ];
    let _ = namespace;
    Ok(placeholder)
}

fn load_asset_index(resource_dir: &str, version_jar_id: &str) -> Result<AssetsIndex> {
    let version_json = dirs::versions(resource_dir)
        .join(version_jar_id)
        .join(format!("{version_jar_id}.json"));
    let text = std::fs::read_to_string(&version_json)
        .with_context(|| format!("missing version json at {}", version_json.display()))?;
    let info: crate::meta::minecraft::VersionInfo = serde_json::from_str(&text)?;
    let index_path = dirs::assets(resource_dir)
        .join("indexes")
        .join(format!("{}.json", info.asset_index.id));
    let bytes = std::fs::read(&index_path)?;
    Ok(serde_json::from_slice(&bytes)?)
}

fn read_zip_text(zip_path: &Path, inner_path: &str) -> Result<String> {
    let bytes = read_zip_bytes(zip_path, inner_path)?;
    Ok(String::from_utf8(bytes)?)
}

fn read_zip_bytes(zip_path: &Path, inner_path: &str) -> Result<Vec<u8>> {
    let file = std::fs::File::open(zip_path)?;
    let mut archive = ZipArchive::new(file)?;
    let mut entry = archive.by_name(inner_path)?;
    let mut buf = Vec::new();
    entry.read_to_end(&mut buf)?;
    Ok(buf)
}

fn parse_vec3(value: Option<&serde_json::Value>, default: [f64; 3]) -> [f64; 3] {
    value
        .and_then(|v| v.as_array())
        .map(|a| {
            [
                a.first().and_then(|x| x.as_f64()).unwrap_or(default[0]),
                a.get(1).and_then(|x| x.as_f64()).unwrap_or(default[1]),
                a.get(2).and_then(|x| x.as_f64()).unwrap_or(default[2]),
            ]
        })
        .unwrap_or(default)
}

fn flat_item_element() -> Vec<ModelElement> {
    vec![ModelElement {
        from: [0.0, 0.0, 7.5],
        to: [16.0, 16.0, 8.5],
        faces: HashMap::from([(
            "south".into(),
            ModelFace {
                texture_index: 0,
                u0: 0.0,
                v0: 0.0,
                u1: 16.0,
                v1: 16.0,
            },
        )]),
    }]
}

fn flat_item_element_json() -> serde_json::Value {
    serde_json::json!({
        "from": [0, 0, 7.5],
        "to": [16, 16, 8.5],
        "faces": {
            "south": { "uv": [0, 0, 16, 16], "texture": "#all" }
        }
    })
}
