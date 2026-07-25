/// Official Modrinth API v2（默认）。
pub const MODRINTH_API_URL_OFFICIAL: &str = "https://api.modrinth.com/v2/";

// Modrinth 启动器元数据地址
pub const META_URL: &str = "https://launcher-meta.modrinth.com/";

/// Official CurseForge Core API（默认）。
pub const CURSEFORGE_API_URL_OFFICIAL: &str = "https://api.curseforge.com";

/// MCIM mirror host (API + CDN fallback).
pub const MCIM_MIRROR_HOST: &str = "https://mod.mcimirror.top";

/// Modrinth API v2 base URL (trailing slash) — always official; use [mcim_url_candidates] for fallback.
pub fn modrinth_api_url() -> &'static str {
    MODRINTH_API_URL_OFFICIAL
}

/// CurseForge Core API base URL (no trailing slash) — always official; use [mcim_url_candidates] for fallback.
pub fn curseforge_api_url() -> &'static str {
    CURSEFORGE_API_URL_OFFICIAL
}

/// Official URL first, then MCIM mirror when applicable.
pub fn mcim_url_candidates(url: &str) -> Vec<String> {
    let mut out = vec![url.to_string()];
    if let Some(mirror) = mcim_mirror_url(url) {
        if mirror != url {
            out.push(mirror);
        }
    }
    out
}

fn mcim_mirror_url(url: &str) -> Option<String> {
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

/// Default CurseForge API key (override with env `AML_CURSEFORGE_API_KEY`).
pub const CURSEFORGE_API_KEY_DEFAULT: &str =
    "$2a$10$i/H4OmVuV0kTE2CBsnYKkOiGeskyRssc5ehKCNha7cfUJVHOOJ01.";

/// Azul API 基础URL
pub const AZUL_API_BASE_URL: &str =
    "https://api.azul.com/metadata/v1/zulu/packages";
