//! Microsoft / Minecraft authentication (device-code style browser flow helpers).

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use chrono::{Duration, Utc};
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Mutex;

use crate::state::db;
use crate::state::{resource_dir, try_state};

const MSA_CLIENT_ID: &str = "6a3728d6-27a3-4180-99bb-479895b8f88e"; // HMCL public client_id (过渡用，待 AML Azure app 通过 Minecraft 审核后切换回 0b654f2b-47f2-4dd8-af31-b2f4b49e6ef0)
const REDIRECT_URI: &str = "https://login.live.com/oauth20_desktop.srf";

static YGGDRASIL_PENDING: once_cell::sync::Lazy<Mutex<HashMap<String, PendingYggdrasilLogin>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(HashMap::new()));
static DEVICE_CODE_PENDING: once_cell::sync::Lazy<Mutex<HashMap<String, PendingDeviceCodeLogin>>> =
    once_cell::sync::Lazy::new(|| Mutex::new(HashMap::new()));

struct PendingYggdrasilLogin {
    service_id: String,
    api_url: String,
    response: YggdrasilAuthResponse,
    created_at: std::time::Instant,
}

#[derive(Clone)]
struct PendingDeviceCodeLogin {
    device_code: String,
    expires_at: std::time::Instant,
}

#[derive(Clone, Debug, Deserialize, serde::Serialize)]
pub struct YggdrasilProfile {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing)]
    pub skin_url: Option<String>,
}

#[derive(Clone, Debug)]
pub struct YggdrasilLoginBegin {
    pub login_id: String,
    pub profiles: Vec<YggdrasilProfile>,
}

pub async fn refresh_active_msa_if_needed() -> Result<()> {
    let state = try_state()?;
    let Some(account) = db::get_active_account(&state.pool).await? else {
        return Ok(());
    };
    if account.kind != "msa" {
        return Ok(());
    }
    if !token_expires_soon(
        account.access_token.as_deref(),
        account.expires_at.as_deref(),
    ) {
        return Ok(());
    }
    // Best-effort: if refresh token present, try refresh. Failures are ignored for offline play fallback.
    let Some(refresh) = account.refresh_token.filter(|s| !s.is_empty()) else {
        return Ok(());
    };
    let client = crate::config::reqwest_builder().build()?;
    let token_resp: OAuthToken = match client
        .post("https://login.live.com/oauth20_token.srf")
        .form(&[
            ("client_id", MSA_CLIENT_ID),
            ("refresh_token", refresh.as_str()),
            ("grant_type", "refresh_token"),
            ("redirect_uri", REDIRECT_URI),
        ])
        .send()
        .await
    {
        Ok(r) => match r.error_for_status() {
            Ok(r) => r.json().await.unwrap_or(OAuthToken {
                access_token: String::new(),
                refresh_token: None,
            }),
            Err(e) => {
                eprintln!("[AML] MSA token refresh HTTP failed: {e}");
                return Ok(());
            }
        },
        Err(e) => {
            eprintln!("[AML] MSA token refresh request failed: {e}");
            return Ok(());
        }
    };
    if token_resp.access_token.is_empty() {
        eprintln!("[AML] MSA token refresh returned empty access_token");
        return Ok(());
    }
    if let Ok(xbl) = xbox_authenticate(&client, &token_resp.access_token).await {
        if let Ok(xsts) = xbox_xsts(&client, &xbl.token).await {
            if let Some(uhs) = xsts.display_claims.xui.first().map(|u| u.uhs.clone()) {
                if let Ok(mc) = minecraft_login(&client, &uhs, &xsts.token).await {
                    let expires_at = minecraft_token_expiry(&mc);
                    let _ = db::upsert_msa_account(
                        &state.pool,
                        &account.username,
                        &account.uuid,
                        &mc.access_token,
                        token_resp
                            .refresh_token
                            .as_deref()
                            .or(Some(refresh.as_str())),
                        expires_at.as_deref(),
                    )
                    .await;
                }
            }
        }
    }
    Ok(())
}

pub async fn begin_yggdrasil_login(
    service_id: &str,
    username: &str,
    password: &str,
) -> Result<YggdrasilLoginBegin> {
    if username.trim().is_empty() || password.is_empty() {
        anyhow::bail!("请输入账号和密码");
    }
    let state = try_state()?;
    let service = db::get_yggdrasil_service(&state.pool, service_id).await?;
    let api_url = normalize_yggdrasil_api_url(&service.api_url)?;
    let client_token = uuid::Uuid::new_v4().to_string();
    let client = yggdrasil_client()?;
    let response = post_yggdrasil::<YggdrasilAuthResponse>(
        &client,
        &format!("{api_url}/authserver/authenticate"),
        &serde_json::json!({
            "agent": { "name": "Minecraft", "version": 1 },
            "username": username,
            "password": password,
            "clientToken": client_token,
            "requestUser": true
        }),
    )
    .await?;
    let mut profiles = response.available_profiles.clone();
    if let Some(selected) = response.selected_profile.clone() {
        if !profiles.iter().any(|profile| profile.id == selected.id) {
            profiles.push(selected);
        }
    }
    if profiles.is_empty() {
        anyhow::bail!("该账号没有可用的 Minecraft 角色");
    }
    let profiles = futures::future::join_all(profiles.into_iter().map(|mut profile| {
        let client = &client;
        let api_url = &api_url;
        async move {
            profile.skin_url = tokio::time::timeout(
                std::time::Duration::from_secs(5),
                fetch_yggdrasil_skin_url(client, api_url, &profile.id),
            )
            .await
            .ok()
            .flatten();
            profile
        }
    }))
    .await;
    let login_id = uuid::Uuid::new_v4().to_string();
    let mut pending = YGGDRASIL_PENDING.lock().unwrap();
    pending.retain(|_, login| login.created_at.elapsed() < std::time::Duration::from_secs(600));
    pending.insert(
        login_id.clone(),
        PendingYggdrasilLogin {
            service_id: service.id,
            api_url,
            response,
            created_at: std::time::Instant::now(),
        },
    );
    Ok(YggdrasilLoginBegin { login_id, profiles })
}

pub async fn finish_yggdrasil_login(
    login_id: &str,
    profile_id: &str,
) -> Result<crate::state::models::Account> {
    let pending = YGGDRASIL_PENDING
        .lock()
        .unwrap()
        .remove(login_id)
        .ok_or_else(|| anyhow!("Yggdrasil 登录会话已失效，请重新登录"))?;
    let profile = pending
        .response
        .available_profiles
        .iter()
        .chain(pending.response.selected_profile.iter())
        .find(|profile| profile.id == profile_id)
        .cloned()
        .ok_or_else(|| anyhow!("所选角色不属于该账号"))?;

    let (access_token, client_token, selected_profile) = if pending
        .response
        .selected_profile
        .as_ref()
        .is_some_and(|selected| selected.id == profile.id)
    {
        (
            pending.response.access_token,
            pending.response.client_token,
            profile,
        )
    } else {
        let client = yggdrasil_client()?;
        let refreshed = post_yggdrasil::<YggdrasilAuthResponse>(
            &client,
            &format!("{}/authserver/refresh", pending.api_url),
            &serde_json::json!({
                "accessToken": pending.response.access_token,
                "clientToken": pending.response.client_token,
                "selectedProfile": profile,
                "requestUser": true
            }),
        )
        .await?;
        let selected = refreshed
            .selected_profile
            .ok_or_else(|| anyhow!("验证服务器未返回所选角色"))?;
        (refreshed.access_token, refreshed.client_token, selected)
    };

    let expires_at = yggdrasil_validation_expiry();
    let state = try_state()?;
    let account = db::upsert_yggdrasil_account(
        &state.pool,
        &pending.service_id,
        &selected_profile.name,
        &selected_profile.id,
        &access_token,
        &client_token,
        &expires_at,
    )
    .await?;
    if let Ok(resource) = resource_dir().await {
        tokio::spawn(async move {
            if let Err(error) = super::authlib_injector::ensure_authlib_injector(&resource).await {
                eprintln!("[AML] authlib-injector preload failed: {error:#}");
            }
        });
    }
    Ok(account)
}

pub async fn refresh_active_account_if_needed() -> Result<()> {
    let state = try_state()?;
    let Some(account) = db::get_active_account(&state.pool).await? else {
        return Ok(());
    };
    if account.kind == "msa" {
        return refresh_active_msa_if_needed().await;
    }
    if account.kind != "yggdrasil" {
        return Ok(());
    }
    if account
        .expires_at
        .as_deref()
        .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
        .is_some_and(|expiry| expiry.with_timezone(&Utc) > Utc::now())
    {
        return Ok(());
    }
    let service_id = account
        .auth_server_id
        .as_deref()
        .ok_or_else(|| anyhow!("外置账号缺少验证服务器配置"))?;
    let access_token = account
        .access_token
        .as_deref()
        .ok_or_else(|| anyhow!("外置账号缺少 access token"))?;
    let client_token = account
        .client_token
        .as_deref()
        .ok_or_else(|| anyhow!("外置账号缺少 client token"))?;
    let service = db::get_yggdrasil_service(&state.pool, service_id).await?;
    let api_url = normalize_yggdrasil_api_url(&service.api_url)?;
    let client = yggdrasil_client()?;
    let validate = client
        .post(format!("{api_url}/authserver/validate"))
        .json(&serde_json::json!({
            "accessToken": access_token,
            "clientToken": client_token
        }))
        .send()
        .await;
    let expires_at = yggdrasil_validation_expiry();
    if validate
        .as_ref()
        .is_ok_and(|response| response.status().is_success())
    {
        return db::update_yggdrasil_account_token(
            &state.pool,
            &account.id,
            access_token,
            client_token,
            &expires_at,
        )
        .await;
    }
    let refreshed = post_yggdrasil::<YggdrasilAuthResponse>(
        &client,
        &format!("{api_url}/authserver/refresh"),
        &serde_json::json!({
            "accessToken": access_token,
            "clientToken": client_token,
            "selectedProfile": {
                "id": account.uuid,
                "name": account.username
            },
            "requestUser": true
        }),
    )
    .await?;
    db::update_yggdrasil_account_token(
        &state.pool,
        &account.id,
        &refreshed.access_token,
        &refreshed.client_token,
        &expires_at,
    )
    .await
}

pub fn normalize_yggdrasil_api_url(value: &str) -> Result<String> {
    let trimmed = value.trim().trim_end_matches('/');
    let url = url::Url::parse(trimmed).context("Yggdrasil API 地址无效")?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        anyhow::bail!("Yggdrasil API 地址必须是有效的 HTTP(S) 地址");
    }
    Ok(trimmed.to_string())
}

fn yggdrasil_client() -> Result<reqwest::Client> {
    Ok(crate::config::reqwest_builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()?)
}

async fn post_yggdrasil<T: serde::de::DeserializeOwned>(
    client: &reqwest::Client,
    url: &str,
    body: &serde_json::Value,
) -> Result<T> {
    let response = client.post(url).json(body).send().await?;
    let status = response.status();
    let text = response.text().await?;
    if !status.is_success() {
        let message = serde_json::from_str::<YggdrasilError>(&text)
            .ok()
            .and_then(|error| error.error_message.or(error.cause).or(error.error))
            .unwrap_or_else(|| format!("Yggdrasil 请求失败: HTTP {status}"));
        anyhow::bail!("{message}");
    }
    serde_json::from_str(&text).context("解析 Yggdrasil 响应失败")
}

fn yggdrasil_validation_expiry() -> String {
    (Utc::now() + Duration::minutes(10)).to_rfc3339()
}

async fn fetch_yggdrasil_skin_url(
    client: &reqwest::Client,
    api_url: &str,
    profile_id: &str,
) -> Option<String> {
    let response = client
        .get(format!(
            "{api_url}/sessionserver/session/minecraft/profile/{profile_id}"
        ))
        .query(&[("unsigned", "false")])
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?;
    let profile: YggdrasilSessionProfile = response.json().await.ok()?;
    let texture = profile
        .properties
        .into_iter()
        .find(|property| property.name == "textures")?;
    let encoded = texture.value;
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(&encoded)
        .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(&encoded))
        .or_else(|_| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(&encoded))
        .ok()?;
    let payload: serde_json::Value = serde_json::from_slice(&decoded).ok()?;
    let skin_url = payload
        .pointer("/textures/SKIN/url")
        .and_then(serde_json::Value::as_str)?;
    let parsed = url::Url::parse(skin_url).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return None;
    }
    Some(skin_url.to_string())
}

#[derive(Deserialize)]
struct OAuthToken {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct YggdrasilAuthResponse {
    access_token: String,
    client_token: String,
    #[serde(default)]
    available_profiles: Vec<YggdrasilProfile>,
    #[serde(default)]
    selected_profile: Option<YggdrasilProfile>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct YggdrasilError {
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    error_message: Option<String>,
    #[serde(default)]
    cause: Option<String>,
}

#[derive(Deserialize)]
struct YggdrasilSessionProfile {
    #[serde(default)]
    properties: Vec<YggdrasilProperty>,
}

#[derive(Deserialize)]
struct YggdrasilProperty {
    name: String,
    value: String,
}

#[derive(Deserialize)]
struct XboxAuth {
    #[serde(rename = "Token")]
    token: String,
}

#[derive(Deserialize)]
struct XstsAuth {
    #[serde(rename = "Token")]
    token: String,
    #[serde(rename = "DisplayClaims")]
    display_claims: DisplayClaims,
}

#[derive(Deserialize)]
struct DisplayClaims {
    xui: Vec<Xui>,
}

#[derive(Deserialize)]
struct Xui {
    uhs: String,
}

#[derive(Deserialize)]
struct McToken {
    access_token: String,
    #[serde(default)]
    expires_in: Option<i64>,
}

fn minecraft_token_expiry(token: &McToken) -> Option<String> {
    token
        .expires_in
        .map(|seconds| (Utc::now() + Duration::seconds(seconds)).to_rfc3339())
        .or_else(|| jwt_expiry(&token.access_token).map(|expiry| expiry.to_rfc3339()))
}

fn token_expires_soon(access_token: Option<&str>, expires_at: Option<&str>) -> bool {
    let refresh_before = Utc::now() + Duration::minutes(5);
    if let Some(expiry) = expires_at
        .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc))
    {
        return expiry <= refresh_before;
    }
    match access_token.and_then(jwt_expiry) {
        Some(expiry) => expiry <= refresh_before,
        None => true,
    }
}

fn jwt_expiry(token: &str) -> Option<chrono::DateTime<Utc>> {
    let payload = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(payload))
        .ok()?;
    let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    let timestamp = value.get("exp")?.as_i64()?;
    chrono::DateTime::from_timestamp(timestamp, 0)
}

#[derive(Deserialize)]
struct McProfile {
    id: String,
    name: String,
}

async fn xbox_authenticate(client: &reqwest::Client, rps: &str) -> Result<XboxAuth> {
    let body = serde_json::json!({
        "Properties": {
            "AuthMethod": "RPS",
            "SiteName": "user.auth.xboxlive.com",
            "RpsTicket": format!("d={rps}")
        },
        "RelyingParty": "http://auth.xboxlive.com",
        "TokenType": "JWT"
    });
    Ok(client
        .post("https://user.auth.xboxlive.com/user/authenticate")
        .json(&body)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?)
}

async fn xbox_xsts(client: &reqwest::Client, xbl_token: &str) -> Result<XstsAuth> {
    let body = serde_json::json!({
        "Properties": {
            "SandboxId": "RETAIL",
            "UserTokens": [xbl_token]
        },
        "RelyingParty": "rp://api.minecraftservices.com/",
        "TokenType": "JWT"
    });
    Ok(client
        .post("https://xsts.auth.xboxlive.com/xsts/authorize")
        .json(&body)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?)
}

async fn minecraft_login(client: &reqwest::Client, uhs: &str, xsts: &str) -> Result<McToken> {
    let body = serde_json::json!({
        "identityToken": format!("XBL3.0 x={uhs};{xsts}")
    });
    Ok(client
        .post("https://api.minecraftservices.com/authentication/login_with_xbox")
        .json(&body)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?)
}

async fn minecraft_profile(client: &reqwest::Client, access_token: &str) -> Result<McProfile> {
    Ok(client
        .get("https://api.minecraftservices.com/minecraft/profile")
        .bearer_auth(access_token)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await
        .context("fetch minecraft profile")?)
}

// ──────────────────────────────────────────────────────────────────────────
// Device Code OAuth2 flow (cross-platform, no WebView / no localhost server)
// ──────────────────────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct DeviceCodeLoginBegin {
    pub login_id: String,
    pub user_code: String,
    pub verification_uri: String,
    pub interval: u64,
    pub expires_in: u64,
    pub message: String,
}

/// Begin device-code MSA login. The Flutter side displays the returned
/// `user_code` + `verification_uri`, opens the browser, then polls
/// `poll_device_code(login_id)` until the user completes authentication.
pub async fn begin_device_code_login() -> Result<DeviceCodeLoginBegin> {
    let client = crate::config::reqwest_builder().build()?;
    let resp = client
        .post("https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode")
        .form(&[
            ("client_id", MSA_CLIENT_ID),
            ("scope", "XboxLive.signin offline_access"),
        ])
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await?
        .error_for_status()?;

    #[derive(Deserialize)]
    struct DeviceCodeResp {
        device_code: String,
        user_code: String,
        verification_uri: String,
        interval: u64,
        expires_in: u64,
        message: String,
    }
    let body: DeviceCodeResp = resp.json().await?;

    let login_id = uuid::Uuid::new_v4().to_string();
    let expires_at =
        std::time::Instant::now() + std::time::Duration::from_secs(body.expires_in);

    DEVICE_CODE_PENDING.lock().unwrap().insert(
        login_id.clone(),
        PendingDeviceCodeLogin {
            device_code: body.device_code,
            expires_at,
        },
    );

    Ok(DeviceCodeLoginBegin {
        login_id,
        user_code: body.user_code,
        verification_uri: body.verification_uri,
        interval: body.interval,
        expires_in: body.expires_in,
        message: body.message,
    })
}

#[derive(Clone, Debug)]
pub enum DeviceCodePollResult {
    Pending,
    Expired,
    Declined,
    SlowDown,
    Success { account: crate::state::models::Account },
}

/// Poll Microsoft's token endpoint for the result of a device-code login.
pub async fn poll_device_code(
    login_id: &str,
) -> Result<DeviceCodePollResult> {
    let pending_clone = {
        let map = DEVICE_CODE_PENDING.lock().unwrap();
        map.get(login_id).cloned()
    };
    let pending = match pending_clone {
        Some(p) => p,
        None => return Ok(DeviceCodePollResult::Expired),
    };

    if pending.expires_at < std::time::Instant::now() {
        DEVICE_CODE_PENDING.lock().unwrap().remove(login_id);
        return Ok(DeviceCodePollResult::Expired);
    }

    let client = crate::config::reqwest_builder().build()?;
    let resp = client
        .post("https://login.microsoftonline.com/consumers/oauth2/v2.0/token")
        .form(&[
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("client_id", MSA_CLIENT_ID),
            ("device_code", pending.device_code.as_str()),
        ])
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await?;

    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();

    if !status.is_success() {
        #[derive(Deserialize)]
        struct ErrorBody {
            error: Option<String>,
            suggestion: Option<String>,
        }
        let body: ErrorBody = serde_json::from_str(&text).unwrap_or(ErrorBody {
            error: None,
            suggestion: None,
        });
        match body.error.as_deref() {
            Some("authorization_pending") => return Ok(DeviceCodePollResult::Pending),
            Some("slow_down") => {
                return Ok(DeviceCodePollResult::SlowDown);
            }
            Some("authorization_declined") => {
                DEVICE_CODE_PENDING.lock().unwrap().remove(login_id);
                return Ok(DeviceCodePollResult::Declined);
            }
            Some("expired_token") => {
                DEVICE_CODE_PENDING.lock().unwrap().remove(login_id);
                return Ok(DeviceCodePollResult::Expired);
            }
            Some("bad_verification_code") => {
                DEVICE_CODE_PENDING.lock().unwrap().remove(login_id);
                return Err(anyhow!("device_code 验证失败"));
            }
            other => return Err(anyhow!("MS device_code error ({other:?}): {text}")),
        }
    }

    let token_resp: OAuthToken = serde_json::from_str(&text)
        .map_err(|e| anyhow!("parse device_code token: {e} — {text}"))?;

    DEVICE_CODE_PENDING.lock().unwrap().remove(login_id);

    let xbl = xbox_authenticate(&client, &token_resp.access_token).await?;
    let xsts = xbox_xsts(&client, &xbl.token).await?;
    let uhs = xsts
        .display_claims
        .xui
        .first()
        .map(|u| u.uhs.clone())
        .ok_or_else(|| anyhow!("missing uhs"))?;
    let mc_token = minecraft_login(&client, &uhs, &xsts.token).await?;
    let profile = minecraft_profile(&client, &mc_token.access_token).await?;
    let expires_at = minecraft_token_expiry(&mc_token);

    let state = try_state()?;
    let account = db::upsert_msa_account(
        &state.pool,
        &profile.name,
        &profile.id,
        &mc_token.access_token,
        token_resp.refresh_token.as_deref(),
        expires_at.as_deref(),
    )
    .await?;

    Ok(DeviceCodePollResult::Success { account })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jwt_with_exp(exp: i64) -> String {
        let payload = serde_json::json!({ "exp": exp }).to_string();
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(payload.as_bytes());
        format!("header.{encoded}.signature")
    }

    #[test]
    fn keeps_minecraft_token_when_expiry_is_not_near() {
        let token = jwt_with_exp((Utc::now() + Duration::hours(1)).timestamp());
        assert!(!token_expires_soon(Some(&token), None));
    }

    #[test]
    fn refreshes_expired_minecraft_token() {
        let token = jwt_with_exp((Utc::now() - Duration::minutes(1)).timestamp());
        assert!(token_expires_soon(Some(&token), None));
    }

    #[test]
    fn normalizes_yggdrasil_api_url() {
        assert_eq!(
            normalize_yggdrasil_api_url("https://littleskin.cn/api/yggdrasil/").unwrap(),
            "https://littleskin.cn/api/yggdrasil"
        );
        assert!(normalize_yggdrasil_api_url("file:///tmp/yggdrasil").is_err());
    }
}
