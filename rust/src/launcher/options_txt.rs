//! Read/write Minecraft `options.txt` (`key:value` lines).

use anyhow::{Context, Result};
use regex::Regex;
use std::path::Path;

/// Upsert `key:value` entries in `{instance}/options.txt`.
///
/// Creates the file when missing. Existing keys are replaced in place;
/// missing keys are appended.
pub async fn upsert_options_txt(path: &Path, pairs: &[(&str, &str)]) -> Result<()> {
    if pairs.is_empty() {
        return Ok(());
    }

    let mut options = if path.is_file() {
        tokio::fs::read_to_string(path)
            .await
            .with_context(|| format!("read {}", path.display()))?
    } else {
        String::new()
    };

    for &(key, value) in pairs {
        let key = key.trim();
        let value = value.trim();
        if key.is_empty() {
            continue;
        }
        let re = Regex::new(&format!(r"(?m)^{}:.*$", regex::escape(key)))
            .context("compile options.txt key regex")?;
        let line = format!("{key}:{value}");
        if re.is_match(&options) {
            options = re.replace_all(&options, line.as_str()).into_owned();
        } else {
            if !options.is_empty() && !options.ends_with('\n') {
                options.push('\n');
            }
            options.push_str(&line);
            options.push('\n');
        }
    }

    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await.ok();
    }
    tokio::fs::write(path, options)
        .await
        .with_context(|| format!("write {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[tokio::test]
    async fn upserts_and_replaces() {
        let dir = std::env::temp_dir().join(format!(
            "aml_options_txt_{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = tokio::fs::create_dir_all(&dir).await;
        let path = dir.join("options.txt");
        tokio::fs::write(&path, "fov:0.5\nlang:en_us\n").await.unwrap();
        upsert_options_txt(&path, &[("lang", "zh_cn"), ("fullscreen", "true")])
            .await
            .unwrap();
        let body = tokio::fs::read_to_string(&path).await.unwrap();
        assert!(body.contains("lang:zh_cn"), "{body}");
        assert!(!body.contains("lang:en_us"), "{body}");
        assert!(body.contains("fullscreen:true"), "{body}");
        assert!(body.contains("fov:0.5"), "{body}");
        let _ = tokio::fs::remove_dir_all(&dir).await;
    }
}
