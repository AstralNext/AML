use chrono::Utc;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum InstallStage {
    NotInstalled,
    Installing,
    Installed,
    Failed,
}

impl InstallStage {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::NotInstalled => "not_installed",
            Self::Installing => "installing",
            Self::Installed => "installed",
            Self::Failed => "failed",
        }
    }

    pub fn parse(s: &str) -> Self {
        match s {
            "installing" => Self::Installing,
            "installed" => Self::Installed,
            "failed" => Self::Failed,
            _ => Self::NotInstalled,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ModLoader {
    Vanilla,
    Fabric,
    Forge,
    Quilt,
    NeoForge,
}

impl ModLoader {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Vanilla => "vanilla",
            Self::Fabric => "fabric",
            Self::Forge => "forge",
            Self::Quilt => "quilt",
            Self::NeoForge => "neoforge",
        }
    }

    pub fn as_meta_str(&self) -> &'static str {
        match self {
            Self::NeoForge => "neo",
            other => other.as_str(),
        }
    }

    pub fn parse(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "fabric" => Self::Fabric,
            "forge" => Self::Forge,
            "quilt" => Self::Quilt,
            "neoforge" | "neo" => Self::NeoForge,
            _ => Self::Vanilla,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UpdateChannel {
    Release,
    Beta,
    Alpha,
}

impl UpdateChannel {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Release => "release",
            Self::Beta => "beta",
            Self::Alpha => "alpha",
        }
    }

    pub fn parse(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "beta" => Self::Beta,
            "alpha" => Self::Alpha,
            _ => Self::Release,
        }
    }

    /// Prefer the less-stable of preferred channel and installed channel.
    pub fn least_stable(self, other: Self) -> Self {
        use UpdateChannel::*;
        match (self, other) {
            (Alpha, _) | (_, Alpha) => Alpha,
            (Beta, _) | (_, Beta) => Beta,
            _ => Release,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Instance {
    pub id: String,
    pub path: String,
    pub name: String,
    pub game_version: String,
    pub loader: String,
    pub loader_version: Option<String>,
    pub install_stage: String,
    pub java_path: Option<String>,
    pub memory_mb: Option<i64>,
    pub extra_jvm_args: Option<String>,
    pub window_width: Option<i64>,
    pub window_height: Option<i64>,
    pub fullscreen: Option<bool>,
    pub environment_vars: Option<String>,
    pub pre_launch_command: Option<String>,
    pub wrapper_command: Option<String>,
    pub post_exit_command: Option<String>,
    pub update_channel: String,
    /// When true, backup the played world after Minecraft exits.
    #[serde(default)]
    pub auto_backup_worlds: bool,
    pub groups: Vec<String>,
    pub modpack_project_id: Option<String>,
    pub modpack_version_id: Option<String>,
    pub modpack_version_number: Option<String>,
    pub modpack_source: Option<String>,
    pub modpack_title: Option<String>,
    pub icon: Option<String>,
    pub last_played: Option<String>,
    pub created_at: String,
}

/// Global launch defaults used when an instance field is unset.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LaunchDefaults {
    pub memory_mb: i64,
    pub extra_jvm_args: Option<String>,
    pub window_width: i64,
    pub window_height: i64,
    pub fullscreen: bool,
    pub environment_vars: Option<String>,
    pub pre_launch_command: Option<String>,
    pub wrapper_command: Option<String>,
    pub post_exit_command: Option<String>,
    /// Minecraft `options.txt` language code, e.g. `zh_cn`. Empty = do not force.
    #[serde(default)]
    pub game_language: Option<String>,
}

impl Default for LaunchDefaults {
    fn default() -> Self {
        Self {
            memory_mb: 4096,
            extra_jvm_args: None,
            window_width: 854,
            window_height: 480,
            fullscreen: false,
            environment_vars: None,
            pre_launch_command: None,
            wrapper_command: None,
            post_exit_command: None,
            game_language: Some("zh_cn".into()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Account {
    pub id: String,
    pub kind: String,
    pub username: String,
    pub uuid: String,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub client_token: Option<String>,
    pub auth_server_id: Option<String>,
    pub expires_at: Option<String>,
    pub active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct YggdrasilService {
    pub id: String,
    pub name: String,
    pub api_url: String,
    pub builtin: bool,
}

#[derive(Debug, Clone)]
pub struct CreateInstanceRequest {
    pub name: String,
    pub game_version: String,
    pub loader: ModLoader,
    pub loader_version: Option<String>,
    pub icon: Option<String>,
}

pub fn offline_uuid(username: &str) -> String {
    use sha1::{Digest, Sha1};
    let mut hasher = Sha1::new();
    hasher.update(format!("OfflinePlayer:{username}").as_bytes());
    let hash = hasher.finalize();
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&hash[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x30;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    uuid::Uuid::from_bytes(bytes).to_string()
}

pub fn now_rfc3339() -> String {
    Utc::now().to_rfc3339()
}
