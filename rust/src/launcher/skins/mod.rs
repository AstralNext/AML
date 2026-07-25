//! Skin library: list / normalize / save / equip.

mod defaults;
mod mojang;
mod png_util;

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use sha2::{Digest, Sha256};
use std::path::PathBuf;

use crate::launcher::auth;
use crate::state::{db, resource_dir, try_state};

pub use png_util::{detect_slim, normalize_skin_texture};

#[derive(Debug, Clone)]
pub struct SkinInfo {
    pub texture_key: String,
    pub name: Option<String>,
    pub section: Option<String>,
    pub variant: String,
    pub cape_id: Option<String>,
    /// data:image/png;base64,... for Flutter Image.memory
    pub texture_data_url: String,
    pub source: String, // default | custom | custom_external
    pub is_equipped: bool,
}

#[derive(Debug, Clone)]
pub struct CapeInfo {
    pub id: String,
    pub name: String,
    pub texture_data_url: String,
    pub is_equipped: bool,
}

fn skins_dir(resource: &std::path::Path) -> PathBuf {
    resource.join("skins")
}

fn cache_dir(resource: &std::path::Path) -> PathBuf {
    skins_dir(resource).join("cache")
}

fn custom_dir(resource: &std::path::Path, user_uuid: &str) -> PathBuf {
    skins_dir(resource).join("custom").join(user_uuid)
}

fn to_data_url(png: &[u8]) -> String {
    format!(
        "data:image/png;base64,{}",
        base64::engine::general_purpose::STANDARD.encode(png)
    )
}

fn local_key(png: &[u8]) -> String {
    let hash = Sha256::digest(png);
    format!("local-{}", hex::encode(hash))
}

async fn ensure_dirs(resource: &std::path::Path) -> Result<()> {
    tokio::fs::create_dir_all(cache_dir(resource)).await?;
    Ok(())
}

async fn load_or_fetch_png(resource: &std::path::Path, key: &str, url: &str) -> Result<Vec<u8>> {
    let path = cache_dir(resource).join(format!("{key}.png"));
    if path.exists() {
        return Ok(tokio::fs::read(&path).await?);
    }
    let bytes = mojang::download_bytes(url).await?;
    let _ = tokio::fs::write(&path, &bytes).await;
    Ok(bytes)
}

async fn active_account() -> Result<crate::state::models::Account> {
    let state = try_state()?;
    db::get_active_account(&state.pool)
        .await?
        .ok_or_else(|| anyhow!("没有活动账号"))
}

pub async fn list_available_skins() -> Result<Vec<SkinInfo>> {
    let account = active_account().await?;
    let resource = PathBuf::from(resource_dir().await?);
    ensure_dirs(&resource).await?;
    let state = try_state()?;
    let uuid = account.uuid.clone();

    // Prefer local preference first (instant), refine with Mojang in parallel.
    let mut equipped_key: Option<String> = db::get_skin_preference(&state.pool, &uuid)
        .await
        .ok()
        .flatten()
        .map(|p| p.texture_key);

    let token = account.access_token.clone();
    let is_msa = account.kind == "msa";
    let pool = state.pool.clone();

    let profile_fut = async {
        if !is_msa {
            return None;
        }
        let Some(token) = token.as_deref() else {
            return None;
        };
        let _ = auth::refresh_active_msa_if_needed().await;
        mojang::fetch_profile(token).await.ok()
    };

    let customs_fut = async {
        let rows = db::list_custom_skins(&pool, &uuid)
            .await
            .unwrap_or_default();
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let path = PathBuf::from(&row.file_path);
            let Ok(bytes) = tokio::fs::read(&path).await else {
                continue;
            };
            let (norm, _) = normalize_skin_texture(&bytes).unwrap_or((bytes, vec![]));
            out.push((row, norm));
        }
        out
    };

    // Defaults removed — wardrobe / editor browse MineSkin instead.

    let (profile, customs) = tokio::join!(profile_fut, customs_fut);

    let mut profile_skin: Option<mojang::ProfileSkin> = None;
    if let Some(profile) = profile {
        if let Some(skin) = profile
            .skins
            .into_iter()
            .find(|s| s.state.eq_ignore_ascii_case("ACTIVE"))
        {
            if equipped_key.is_none() {
                equipped_key = skin
                    .texture_key
                    .clone()
                    .or_else(|| skin.url.rsplit('/').next().map(|s| s.to_string()));
            }
            profile_skin = Some(skin);
        }
    }

    let mut out = Vec::with_capacity(customs.len() + 1);

    for (row, norm) in customs {
        let equipped = equipped_key
            .as_ref()
            .map(|k| k == &row.texture_key)
            .unwrap_or(false);
        out.push(SkinInfo {
            texture_key: row.texture_key,
            name: row.name,
            section: Some("已保存皮肤".into()),
            variant: row.variant,
            cape_id: row.cape_id,
            texture_data_url: to_data_url(&norm),
            source: "custom".into(),
            is_equipped: equipped,
        });
    }

    if let Some(skin) = profile_skin {
        let key = skin.texture_key.clone().unwrap_or_else(|| {
            skin.url
                .rsplit('/')
                .next()
                .unwrap_or("external")
                .to_string()
        });
        if !out.iter().any(|s| s.texture_key == key) {
            if let Ok(bytes) = load_or_fetch_png(&resource, &key, &skin.url).await {
                let (norm, _) = normalize_skin_texture(&bytes).unwrap_or((bytes, vec![]));
                let equipped = equipped_key.as_ref().map(|k| k == &key).unwrap_or(true);
                out.push(SkinInfo {
                    texture_key: key,
                    name: Some("当前皮肤".into()),
                    section: Some("已保存皮肤".into()),
                    variant: skin.variant.to_lowercase(),
                    cape_id: None,
                    texture_data_url: to_data_url(&norm),
                    source: "custom_external".into(),
                    is_equipped: equipped,
                });
            }
        }
    }

    if !out.iter().any(|s| s.is_equipped) {
        if let Some(first) = out.first_mut() {
            first.is_equipped = true;
        }
    }

    Ok(out)
}

pub async fn list_available_capes() -> Result<Vec<CapeInfo>> {
    let _ = auth::refresh_active_msa_if_needed().await;
    let account = active_account().await?;
    if account.kind != "msa" {
        return Ok(vec![]);
    }
    let token = account
        .access_token
        .as_deref()
        .ok_or_else(|| anyhow!("缺少 access token"))?;
    let profile = mojang::fetch_profile(token).await?;
    let resource = PathBuf::from(resource_dir().await?);
    ensure_dirs(&resource).await?;

    let mut out = Vec::new();
    for cape in profile.capes {
        let bytes = match mojang::download_bytes(&cape.url).await {
            Ok(b) => b,
            Err(_) => continue,
        };
        out.push(CapeInfo {
            id: cape.id,
            name: cape.alias.unwrap_or_else(|| "Cape".into()),
            texture_data_url: to_data_url(&bytes),
            is_equipped: cape.state.eq_ignore_ascii_case("ACTIVE"),
        });
    }
    Ok(out)
}

pub async fn normalize_skin_bytes(png_bytes: Vec<u8>) -> Result<Vec<u8>> {
    let (norm, _) = normalize_skin_texture(&png_bytes)?;
    Ok(norm)
}

pub async fn detect_skin_variant(png_bytes: Vec<u8>) -> Result<String> {
    let (_, rgba) = normalize_skin_texture(&png_bytes)?;
    Ok(if detect_slim(&rgba) {
        "slim".into()
    } else {
        "classic".into()
    })
}

pub async fn save_custom_skin(
    png_bytes: Vec<u8>,
    name: Option<String>,
    variant: String,
    cape_id: Option<String>,
) -> Result<SkinInfo> {
    let (w, h) = png_util::dimensions(&png_bytes)?;
    if w != 64 || ![32, 64].contains(&h) {
        anyhow::bail!("皮肤尺寸必须是 64×64 或 64×32");
    }
    let variant = match variant.to_lowercase().as_str() {
        "slim" => "slim",
        _ => "classic",
    }
    .to_string();

    let account = active_account().await?;
    let resource = PathBuf::from(resource_dir().await?);
    let dir = custom_dir(&resource, &account.uuid);
    tokio::fs::create_dir_all(&dir).await?;

    let key = local_key(&png_bytes);
    let path = dir.join(format!("{key}.png"));
    tokio::fs::write(&path, &png_bytes).await?;

    let state = try_state()?;
    db::upsert_custom_skin(
        &state.pool,
        &account.uuid,
        &key,
        name.as_deref(),
        &variant,
        cape_id.as_deref(),
        &path.to_string_lossy(),
    )
    .await?;

    let (norm, _) = normalize_skin_texture(&png_bytes)?;
    Ok(SkinInfo {
        texture_key: key,
        name,
        section: Some("已保存皮肤".into()),
        variant,
        cape_id,
        texture_data_url: to_data_url(&norm),
        source: "custom".into(),
        is_equipped: false,
    })
}

pub async fn remove_custom_skin(texture_key: String) -> Result<()> {
    let account = active_account().await?;
    let state = try_state()?;
    if let Some(row) = db::get_custom_skin(&state.pool, &account.uuid, &texture_key).await? {
        let _ = tokio::fs::remove_file(&row.file_path).await;
    }
    db::delete_custom_skin(&state.pool, &account.uuid, &texture_key).await?;
    Ok(())
}

pub async fn equip_skin(
    texture_key: String,
    variant: String,
    cape_id: Option<String>,
    texture_data_url: Option<String>,
) -> Result<()> {
    let _ = auth::refresh_active_msa_if_needed().await;
    let account = active_account().await?;
    let state = try_state()?;
    let resource = PathBuf::from(resource_dir().await?);
    ensure_dirs(&resource).await?;

    let variant = match variant.to_lowercase().as_str() {
        "slim" => "slim",
        _ => "classic",
    };

    // Resolve PNG bytes
    let png_bytes =
        if let Some(row) = db::get_custom_skin(&state.pool, &account.uuid, &texture_key).await? {
            tokio::fs::read(&row.file_path).await?
        } else if let Some(def) = defaults::DEFAULT_SKINS
            .iter()
            .find(|d| d.texture_key == texture_key)
        {
            def.png.to_vec()
        } else if let Some(data_url) = texture_data_url {
            mojang::download_bytes(&data_url).await?
        } else if texture_key.starts_with("local-") {
            anyhow::bail!("找不到自定义皮肤文件");
        } else {
            let url = defaults::texture_cdn_url(&texture_key);
            load_or_fetch_png(&resource, &texture_key, &url).await?
        };

    db::set_skin_preference(
        &state.pool,
        &account.uuid,
        &texture_key,
        variant,
        cape_id.as_deref(),
    )
    .await?;

    if account.kind == "msa" {
        let token = account
            .access_token
            .as_deref()
            .ok_or_else(|| anyhow!("缺少 access token，请重新登录微软账号"))?;
        mojang::equip_skin(token, png_bytes, variant)
            .await
            .context("上传皮肤到 Mojang 失败")?;

        match &cape_id {
            Some(id) if !id.is_empty() => {
                let _ = mojang::equip_cape(token, id).await;
            }
            _ => {
                let _ = mojang::unequip_cape(token).await;
            }
        }
    }

    Ok(())
}

pub async fn bake_skin_preview(
    texture_data_url: String,
    variant: String,
    scale: u32,
) -> Result<Vec<u8>> {
    let png = mojang::download_bytes(&texture_data_url).await?;
    let (_, rgba) = normalize_skin_texture(&png)?;
    let slim = variant.eq_ignore_ascii_case("slim");
    Ok(render_front_preview(&rgba, slim, scale.max(1)))
}

/// Simple front-facing 2D player preview (head + body + arms + legs).
fn render_front_preview(skin: &[u8], slim: bool, scale: u32) -> Vec<u8> {
    // Layout in skin pixels (front view):
    // Head 8x8 at (8,8), hat (40,8)
    // Body 8x12 at (20,20)
    // Right arm 4x12 at (44,20) or slim 3x12
    // Left arm 4x12 at (36,52) modern / mirrored from right for legacy
    // Right leg 4x12 at (4,20), left leg (20,52)
    let arm_w = if slim { 3usize } else { 4usize };
    let width = (8 + arm_w + 8 + arm_w) as u32; // arms + body
    let height = 32u32; // head+body+legs
    let out_w = width * scale;
    let out_h = height * scale;
    let mut out = vec![0u8; (out_w * out_h * 4) as usize];

    let sample = |sx: usize, sy: usize| -> [u8; 4] {
        let i = (sy * 64 + sx) * 4;
        [
            skin.get(i).copied().unwrap_or(0),
            skin.get(i + 1).copied().unwrap_or(0),
            skin.get(i + 2).copied().unwrap_or(0),
            skin.get(i + 3).copied().unwrap_or(0),
        ]
    };

    let blit = |out: &mut [u8], dx: usize, dy: usize, sx: usize, sy: usize, w: usize, h: usize| {
        for y in 0..h {
            for x in 0..w {
                let px = sample(sx + x, sy + y);
                if px[3] == 0 {
                    continue;
                }
                for sy2 in 0..scale as usize {
                    for sx2 in 0..scale as usize {
                        let ox = (dx + x) * scale as usize + sx2;
                        let oy = (dy + y) * scale as usize + sy2;
                        let oi = (oy * out_w as usize + ox) * 4;
                        out[oi..oi + 4].copy_from_slice(&px);
                    }
                }
            }
        }
    };

    let body_x = arm_w;
    // Head
    blit(&mut out, body_x, 0, 8, 8, 8, 8);
    blit(&mut out, body_x, 0, 40, 8, 8, 8); // hat
                                            // Body
    blit(&mut out, body_x, 8, 20, 20, 8, 12);
    blit(&mut out, body_x, 8, 20, 36, 8, 12); // jacket
                                              // Right arm (viewer left)
    blit(&mut out, 0, 8, 44, 20, arm_w, 12);
    blit(&mut out, 0, 8, 44, 36, arm_w, 12);
    // Left arm
    blit(&mut out, body_x + 8, 8, 36, 52, arm_w, 12);
    blit(&mut out, body_x + 8, 8, 52, 52, arm_w, 12);
    // Right leg
    blit(&mut out, body_x, 20, 4, 20, 4, 12);
    blit(&mut out, body_x, 20, 4, 36, 4, 12);
    // Left leg
    blit(&mut out, body_x + 4, 20, 20, 52, 4, 12);
    blit(&mut out, body_x + 4, 20, 4, 52, 4, 12);

    // Encode PNG
    let mut encoded = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut encoded, out_w, out_h);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut writer = enc.write_header().expect("png header");
        writer.write_image_data(&out).expect("png data");
    }
    encoded
}
