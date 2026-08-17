use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::SystemTime;

/// Official Modrinth API v2（默认）。
pub const MODRINTH_API_URL_OFFICIAL: &str = "https://api.modrinth.com/v2/";

// Modrinth 启动器元数据地址
pub const META_URL: &str = "https://launcher-meta.modrinth.com/";

/// Official CurseForge Core API（默认）。
pub const CURSEFORGE_API_URL_OFFICIAL: &str = "https://api.curseforge.com";

/// MCIM mirror host (API + CDN fallback).
pub const MCIM_MIRROR_HOST: &str = "https://mod.mcimirror.top";

/// Pysio file CDN behind MCIM (Cloudflare).
pub const PYSIO_FILE_HOST: &str = "https://mcim-files.pysio.online";

/// BMCLAPI — Minecraft / Forge / Fabric / authlib, not CurseForge/Modrinth mods.
pub const BMCLAPI_HOST: &str = "https://bmclapi2.bangbang93.com";

fn default_true() -> bool {
    true
}

fn default_false() -> bool {
    false
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CdnSettings {
    #[serde(default = "default_false")]
    pub official_first: bool,
    #[serde(default = "default_true")]
    pub mcim: bool,
    #[serde(default = "default_true")]
    pub pysio: bool,
    #[serde(default = "default_true")]
    pub bmclapi: bool,
}

impl Default for CdnSettings {
    fn default() -> Self {
        Self {
            official_first: false,
            mcim: true,
            pysio: true,
            bmclapi: true,
        }
    }
}

fn default_proxy_mode() -> String {
    "off".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProxySettings {
    #[serde(default = "default_proxy_mode")]
    pub mode: String,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub resolved_url: String,
}

impl Default for ProxySettings {
    fn default() -> Self {
        Self {
            mode: default_proxy_mode(),
            url: String::new(),
            resolved_url: String::new(),
        }
    }
}

static CDN_RESOURCE_DIR: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new(String::new()));
static CDN_CACHE: Lazy<Mutex<Option<(Option<SystemTime>, CdnSettings)>>> =
    Lazy::new(|| Mutex::new(None));
static PROXY_CACHE: Lazy<Mutex<Option<(Option<SystemTime>, ProxySettings)>>> =
    Lazy::new(|| Mutex::new(None));

pub fn set_cdn_resource_dir(dir: &str) {
    if let Ok(mut g) = CDN_RESOURCE_DIR.lock() {
        *g = dir.to_string();
    }
    if let Ok(mut g) = CDN_CACHE.lock() {
        *g = None;
    }
    if let Ok(mut g) = PROXY_CACHE.lock() {
        *g = None;
    }
}

fn cdn_settings_path() -> Option<PathBuf> {
    let dir = CDN_RESOURCE_DIR.lock().ok()?;
    if dir.is_empty() {
        return None;
    }
    Some(PathBuf::from(dir.clone()).join("cdn_settings.json"))
}

pub fn cdn_settings() -> CdnSettings {
    let path = match cdn_settings_path() {
        Some(p) => p,
        None => return CdnSettings::default(),
    };
    let mtime = fs::metadata(&path).ok().and_then(|m| m.modified().ok());
    if let Ok(cache) = CDN_CACHE.lock() {
        if let Some((cached_mtime, settings)) = cache.as_ref() {
            if *cached_mtime == mtime {
                return settings.clone();
            }
        }
    }
    let settings = fs::read_to_string(&path)
        .ok()
        .and_then(|text| serde_json::from_str::<CdnSettings>(&text).ok())
        .unwrap_or_default();
    if let Ok(mut cache) = CDN_CACHE.lock() {
        *cache = Some((mtime, settings.clone()));
    }
    settings
}

fn proxy_settings_path() -> Option<PathBuf> {
    let dir = CDN_RESOURCE_DIR.lock().ok()?;
    if dir.is_empty() {
        return None;
    }
    Some(PathBuf::from(dir.clone()).join("proxy_settings.json"))
}

pub fn proxy_settings() -> ProxySettings {
    let path = match proxy_settings_path() {
        Some(p) => p,
        None => return ProxySettings::default(),
    };
    let mtime = fs::metadata(&path).ok().and_then(|m| m.modified().ok());
    if let Ok(cache) = PROXY_CACHE.lock() {
        if let Some((cached_mtime, settings)) = cache.as_ref() {
            if *cached_mtime == mtime {
                return settings.clone();
            }
        }
    }
    let settings = fs::read_to_string(&path)
        .ok()
        .and_then(|text| serde_json::from_str::<ProxySettings>(&text).ok())
        .unwrap_or_default();
    if let Ok(mut cache) = PROXY_CACHE.lock() {
        *cache = Some((mtime, settings.clone()));
    }
    settings
}

pub fn proxy_fingerprint() -> String {
    let s = proxy_settings();
    format!("{}|{}|{}", s.mode, s.url, s.resolved_url)
}

/// Apply launcher proxy settings. Does not set process `HTTP_PROXY`.
pub fn apply_proxy(builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
    let settings = proxy_settings();
    match settings.mode.as_str() {
        "off" => builder.no_proxy(),
        "manual" => match proxy_from_url(&settings.url) {
            Some(proxy) => builder.proxy(proxy),
            None => builder.no_proxy(),
        },
        _ => {
            if let Some(proxy) = proxy_from_url(&settings.resolved_url) {
                builder.proxy(proxy)
            } else {
                builder
            }
        }
    }
}

pub fn reqwest_builder() -> reqwest::ClientBuilder {
    apply_proxy(reqwest::Client::builder().user_agent("AstralMinecraftLauncher/0.1"))
}

fn proxy_from_url(raw: &str) -> Option<reqwest::Proxy> {
    let url = raw.trim();
    if url.is_empty() {
        return None;
    }
    reqwest::Proxy::all(url).ok()
}

/// Modrinth API v2 base URL (trailing slash) — always official; use [mcim_url_candidates] for fallback.
pub fn modrinth_api_url() -> &'static str {
    MODRINTH_API_URL_OFFICIAL
}

/// CurseForge Core API base URL (no trailing slash) — always official; use [mcim_url_candidates] for fallback.
pub fn curseforge_api_url() -> &'static str {
    CURSEFORGE_API_URL_OFFICIAL
}

/// Official URL plus enabled CDN mirrors, ordered by settings.
pub fn mcim_url_candidates(url: &str) -> Vec<String> {
    let settings = cdn_settings();
    let mut mirrors = Vec::new();
    if settings.mcim {
        if let Some(m) = rewrite_mcim(url) {
            if m != url {
                mirrors.push(m);
            }
        }
    }
    if settings.pysio {
        if let Some(m) = rewrite_pysio(url) {
            if m != url && !mirrors.iter().any(|x| x == &m) {
                mirrors.push(m);
            }
        }
    }
    if settings.bmclapi {
        if let Some(m) = rewrite_bmclapi(url) {
            if m != url && !mirrors.iter().any(|x| x == &m) {
                mirrors.push(m);
            }
        }
    }

    let mut out = Vec::new();
    if settings.official_first {
        out.push(url.to_string());
        out.extend(mirrors);
    } else {
        out.extend(mirrors);
        if !out.iter().any(|x| x == url) {
            out.push(url.to_string());
        }
    }
    if out.is_empty() {
        out.push(url.to_string());
    }
    out
}

fn rewrite_mcim(url: &str) -> Option<String> {
    let lower = url.to_lowercase();
    if lower.contains("api.modrinth.com/v2") {
        return Some(
            url.replace("https://api.modrinth.com/v2", &format!("{MCIM_MIRROR_HOST}/modrinth/v2"))
                .replace("http://api.modrinth.com/v2", &format!("{MCIM_MIRROR_HOST}/modrinth/v2")),
        );
    }
    if lower.contains("api.curseforge.com") {
        return Some(
            url.replace("https://api.curseforge.com", &format!("{MCIM_MIRROR_HOST}/curseforge"))
                .replace("http://api.curseforge.com", &format!("{MCIM_MIRROR_HOST}/curseforge")),
        );
    }
    if lower.contains("cdn.modrinth.com") {
        return Some(
            url.replace("https://cdn.modrinth.com", MCIM_MIRROR_HOST)
                .replace("http://cdn.modrinth.com", MCIM_MIRROR_HOST),
        );
    }
    for host in ["edge.forgecdn.net", "mediafilez.forgecdn.net"] {
        if lower.contains(host) {
            return Some(url.replace(host, "mod.mcimirror.top"));
        }
    }
    None
}

fn rewrite_pysio(url: &str) -> Option<String> {
    let lower = url.to_lowercase();
    if lower.contains("cdn.modrinth.com") {
        return Some(
            url.replace("https://cdn.modrinth.com", PYSIO_FILE_HOST)
                .replace("http://cdn.modrinth.com", PYSIO_FILE_HOST),
        );
    }
    for host in ["edge.forgecdn.net", "mediafilez.forgecdn.net"] {
        if lower.contains(host) {
            return Some(url.replace(host, "mcim-files.pysio.online"));
        }
    }
    None
}

fn rewrite_bmclapi(url: &str) -> Option<String> {
    let maven = format!("{BMCLAPI_HOST}/maven");
    let assets = format!("{BMCLAPI_HOST}/assets");
    let replacements = [
        ("https://piston-meta.mojang.com", BMCLAPI_HOST.to_string()),
        ("http://piston-meta.mojang.com", BMCLAPI_HOST.to_string()),
        ("https://piston-data.mojang.com", BMCLAPI_HOST.to_string()),
        ("http://piston-data.mojang.com", BMCLAPI_HOST.to_string()),
        ("https://launchermeta.mojang.com", BMCLAPI_HOST.to_string()),
        ("http://launchermeta.mojang.com", BMCLAPI_HOST.to_string()),
        ("https://launcher.mojang.com", BMCLAPI_HOST.to_string()),
        ("http://launcher.mojang.com", BMCLAPI_HOST.to_string()),
        ("https://libraries.minecraft.net", maven.clone()),
        ("http://libraries.minecraft.net", maven.clone()),
        ("https://resources.download.minecraft.net", assets.clone()),
        ("http://resources.download.minecraft.net", assets),
        ("https://maven.minecraftforge.net", maven.clone()),
        ("http://maven.minecraftforge.net", maven.clone()),
        ("https://files.minecraftforge.net/maven", maven.clone()),
        ("http://files.minecraftforge.net/maven", maven.clone()),
        ("https://maven.neoforged.net/releases", maven.clone()),
        ("http://maven.neoforged.net/releases", maven.clone()),
        ("https://maven.fabricmc.net", maven.clone()),
        ("http://maven.fabricmc.net", maven),
    ];
    for (from, to) in replacements {
        if url.starts_with(from) {
            return Some(url.replacen(from, &to, 1));
        }
    }
    None
}

/// Default CurseForge API key (override with env `AML_CURSEFORGE_API_KEY`).
pub const CURSEFORGE_API_KEY_DEFAULT: &str =
    "$2a$10$i/H4OmVuV0kTE2CBsnYKkOiGeskyRssc5ehKCNha7cfUJVHOOJ01.";

/// Azul API 基础URL
pub const AZUL_API_BASE_URL: &str =
    "https://api.azul.com/metadata/v1/zulu/packages";
