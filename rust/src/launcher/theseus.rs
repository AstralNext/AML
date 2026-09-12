//! Launch agent (`theseus.jar`) resolution.
//!
//! The jar is built by Gradle during `build.rs` and **embedded** into the
//! native library so release packages do not depend on Cargo `OUT_DIR`.

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

pub const LAUNCHER_ENTRY: &str = "com.modrinth.theseus.MinecraftLaunch";

const EMBEDDED_JAR: &[u8] =
    include_bytes!(concat!(env!("JAVA_JARS_DIR"), "/theseus.jar"));

/// Resolve a filesystem path to `theseus.jar` for `-javaagent` / classpath.
///
/// Order:
/// 1. Compile-time `JAVA_JARS_DIR` (Flutter/Cargo build tree — convenient for `flutter run`)
/// 2. Cached copy under `{resource_dir}/meta/launcher/` (release / portable)
pub fn ensure_jar(resource_dir: &str) -> Result<PathBuf> {
    let build_path = PathBuf::from(env!("JAVA_JARS_DIR")).join("theseus.jar");
    if build_path.is_file() {
        return Ok(build_path);
    }

    let cache_dir = PathBuf::from(resource_dir)
        .join(super::dirs::META_DIR)
        .join("launcher");
    let jar_path = cache_dir.join("theseus.jar");
    let stamp_path = cache_dir.join("theseus.jar.sha256");
    let expected = hex::encode(Sha256::digest(EMBEDDED_JAR));

    if jar_is_current(&jar_path, &stamp_path, &expected) {
        return Ok(jar_path);
    }

    std::fs::create_dir_all(&cache_dir)
        .with_context(|| format!("create {}", cache_dir.display()))?;
    std::fs::write(&jar_path, EMBEDDED_JAR)
        .with_context(|| format!("write {}", jar_path.display()))?;
    std::fs::write(&stamp_path, expected.as_bytes())
        .with_context(|| format!("write {}", stamp_path.display()))?;
    Ok(jar_path)
}

pub fn jar_path_string(resource_dir: &str) -> Result<String> {
    Ok(ensure_jar(resource_dir)?
        .to_string_lossy()
        .to_string())
}

fn jar_is_current(jar: &Path, stamp: &Path, expected_hex: &str) -> bool {
    if !jar.is_file() {
        return false;
    }
    match std::fs::read_to_string(stamp) {
        Ok(actual) => actual.trim() == expected_hex,
        Err(_) => false,
    }
}
