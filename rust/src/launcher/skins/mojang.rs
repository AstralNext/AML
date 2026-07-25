//! Minecraft Services skin / cape HTTP (Bearer MC access_token).

use anyhow::{anyhow, Context, Result};
use reqwest::multipart::{Form, Part};
use serde::Deserialize;
use serde_json::json;

#[derive(Debug, Clone, Deserialize)]
pub struct ProfileSkin {
    pub id: String,
    pub state: String,
    pub url: String,
    #[serde(rename = "textureKey", default)]
    pub texture_key: Option<String>,
    pub variant: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProfileCape {
    pub id: String,
    pub state: String,
    pub url: String,
    #[serde(default)]
    pub alias: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FullProfile {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub skins: Vec<ProfileSkin>,
    #[serde(default)]
    pub capes: Vec<ProfileCape>,
}

pub async fn fetch_profile(access_token: &str) -> Result<FullProfile> {
    let client = reqwest::Client::new();
    Ok(client
        .get("https://api.minecraftservices.com/minecraft/profile")
        .bearer_auth(access_token)
        .header("Accept", "application/json")
        .send()
        .await?
        .error_for_status()?
        .json()
        .await
        .context("parse minecraft profile")?)
}

pub async fn equip_skin(
    access_token: &str,
    png_bytes: Vec<u8>,
    variant: &str,
) -> Result<FullProfile> {
    let variant = match variant {
        "slim" | "SLIM" => "slim",
        "classic" | "CLASSIC" => "classic",
        other => other,
    };
    if variant != "slim" && variant != "classic" {
        anyhow::bail!("unknown skin variant");
    }

    let form = Form::new().text("variant", variant.to_string()).part(
        "file",
        Part::bytes(png_bytes)
            .file_name("skin.png")
            .mime_str("image/png")?,
    );

    let client = reqwest::Client::new();
    let resp = client
        .post("https://api.minecraftservices.com/minecraft/profile/skins")
        .bearer_auth(access_token)
        .header("Accept", "application/json")
        .multipart(form)
        .send()
        .await?
        .error_for_status()
        .context("equip skin")?;

    Ok(resp.json().await.context("parse equip response")?)
}

pub async fn equip_cape(access_token: &str, cape_id: &str) -> Result<()> {
    let client = reqwest::Client::new();
    client
        .put("https://api.minecraftservices.com/minecraft/profile/capes/active")
        .bearer_auth(access_token)
        .header("Content-Type", "application/json")
        .json(&json!({ "capeId": cape_id }))
        .send()
        .await?
        .error_for_status()?;
    Ok(())
}

pub async fn unequip_cape(access_token: &str) -> Result<()> {
    let client = reqwest::Client::new();
    client
        .delete("https://api.minecraftservices.com/minecraft/profile/capes/active")
        .bearer_auth(access_token)
        .send()
        .await?
        .error_for_status()?;
    Ok(())
}

pub async fn download_bytes(url: &str) -> Result<Vec<u8>> {
    if let Some(rest) = url.strip_prefix("data:image/png;base64,") {
        use base64::Engine;
        return base64::engine::general_purpose::STANDARD
            .decode(rest)
            .map_err(|e| anyhow!("base64: {e}"));
    }
    let client = reqwest::Client::new();
    Ok(client
        .get(url)
        .header("Accept", "image/png")
        .timeout(std::time::Duration::from_secs(15))
        .send()
        .await?
        .error_for_status()?
        .bytes()
        .await?
        .to_vec())
}
