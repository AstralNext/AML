//! Version compatibility matching + update-channel gating.

use super::modrinth::ModrinthVersion;
use super::types::ContentType;
use crate::state::models::UpdateChannel;

fn version_matches(
    version: &ModrinthVersion,
    content_type: ContentType,
    game_version: &str,
    loaders: &[String],
) -> bool {
    let games = version.game_versions.as_deref().unwrap_or(&[]);
    if !game_version.is_empty() && !games.iter().any(|g| g == game_version) {
        return false;
    }
    if loaders.is_empty() {
        return true;
    }
    let v_loaders = version.loaders.as_deref().unwrap_or(&[]);
    let direct = loaders
        .iter()
        .any(|want| v_loaders.iter().any(|have| loaders_match(want, have)));
    if direct {
        return true;
    }
    // Mods may list datapack loader as compatible fallback
    content_type == ContentType::Mod && v_loaders.iter().any(|l| l == "datapack")
}

fn loaders_match(expected: &str, candidate: &str) -> bool {
    let a = expected.to_lowercase();
    let b = candidate.to_lowercase();
    a == b || (matches!(a.as_str(), "neoforge" | "neo") && matches!(b.as_str(), "neoforge" | "neo"))
}

pub(super) fn infer_channel_from_version(version: &str) -> UpdateChannel {
    let lower = version.to_lowercase();
    if lower.contains("alpha") || lower.contains("-a.") {
        UpdateChannel::Alpha
    } else if lower.contains("beta") || lower.contains("-b.") || lower.contains("rc") {
        UpdateChannel::Beta
    } else {
        UpdateChannel::Release
    }
}

pub(super) fn channel_allows(channel: UpdateChannel, version_type: Option<&str>) -> bool {
    let kind = version_type.unwrap_or("release").to_lowercase();
    match channel {
        UpdateChannel::Release => kind == "release",
        UpdateChannel::Beta => kind == "release" || kind == "beta",
        UpdateChannel::Alpha => true,
    }
}

pub(super) fn select_compatible_version(
    mut versions: Vec<ModrinthVersion>,
    content_type: ContentType,
    game_version: &str,
    loaders: &[String],
) -> Option<ModrinthVersion> {
    versions.sort_by(|a, b| {
        b.date_published
            .as_deref()
            .unwrap_or("")
            .cmp(a.date_published.as_deref().unwrap_or(""))
    });
    versions
        .into_iter()
        .find(|v| version_matches(v, content_type, game_version, loaders))
}
