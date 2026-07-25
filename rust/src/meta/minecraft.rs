use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use super::modded::{Processor, SidedDataEntry};

pub const CURRENT_FORMAT_VERSION: usize = 0;

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "snake_case")]
pub enum VersionType {
    Release,
    Snapshot,
    OldAlpha,
    OldBeta,
}

impl VersionType {
    pub fn as_str(&self) -> &'static str {
        match self {
            VersionType::Release => "release",
            VersionType::Snapshot => "snapshot",
            VersionType::OldAlpha => "old_alpha",
            VersionType::OldBeta => "old_beta",
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Version {
    pub id: String,
    #[serde(rename = "type")]
    pub type_: VersionType,
    pub url: String,
    pub time: DateTime<Utc>,
    pub release_time: DateTime<Utc>,
    pub sha1: String,
    pub compliance_level: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_sha1: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct LatestVersion {
    pub release: String,
    pub snapshot: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct VersionManifest {
    pub latest: LatestVersion,
    pub versions: Vec<Version>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct AssetIndex {
    pub id: String,
    pub sha1: String,
    pub size: u32,
    pub total_size: u32,
    pub url: String,
}

#[derive(Serialize, Deserialize, Debug, Eq, PartialEq, Hash, Clone)]
#[serde(rename_all = "snake_case")]
pub enum DownloadType {
    Client,
    ClientMappings,
    Server,
    ServerMappings,
    WindowsServer,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Download {
    pub sha1: String,
    pub size: u32,
    pub url: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct LibraryDownload {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub sha1: String,
    pub size: u32,
    pub url: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct LibraryDownloads {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artifact: Option<LibraryDownload>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub classifiers: Option<HashMap<String, LibraryDownload>>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "snake_case")]
pub enum RuleAction {
    Allow,
    Disallow,
}

#[derive(Serialize, Deserialize, Debug, Eq, PartialEq, Hash, Clone)]
#[serde(rename_all = "kebab-case")]
pub enum Os {
    Osx,
    OsxArm64,
    Windows,
    WindowsArm64,
    Linux,
    LinuxArm64,
    LinuxArm32,
    Unknown,
}

impl Os {
    pub fn native_arch(java_arch: &str) -> Self {
        if std::env::consts::OS == "windows" {
            if java_arch == "aarch64" {
                Os::WindowsArm64
            } else {
                Os::Windows
            }
        } else if std::env::consts::OS == "linux" {
            if java_arch == "aarch64" {
                Os::LinuxArm64
            } else if java_arch == "arm" {
                Os::LinuxArm32
            } else {
                Os::Linux
            }
        } else if std::env::consts::OS == "macos" {
            if java_arch == "aarch64" {
                Os::OsxArm64
            } else {
                Os::Osx
            }
        } else {
            Os::Unknown
        }
    }

    pub fn get_os(&self) -> Self {
        match self {
            Os::OsxArm64 => Os::Osx,
            Os::LinuxArm32 | Os::LinuxArm64 => Os::Linux,
            Os::WindowsArm64 => Os::Windows,
            _ => self.clone(),
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct OsRule {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<Os>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arch: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct FeatureRule {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_demo_user: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub has_custom_resolution: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub has_quick_plays_support: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_quick_play_singleplayer: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_quick_play_multiplayer: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_quick_play_realms: Option<bool>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Rule {
    pub action: RuleAction,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub os: Option<OsRule>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub features: Option<FeatureRule>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct LibraryExtract {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exclude: Option<Vec<String>>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct JavaVersion {
    pub component: String,
    pub major_version: u32,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Library {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub downloads: Option<LibraryDownloads>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub extract: Option<LibraryExtract>,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub natives: Option<HashMap<Os, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rules: Option<Vec<Rule>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checksums: Option<Vec<String>>,
    #[serde(default = "default_true")]
    pub include_in_classpath: bool,
    #[serde(default = "default_true")]
    pub downloadable: bool,
}

impl Library {
    pub fn natives_os_key_and_classifiers(
        &self,
        java_arch: &str,
    ) -> Option<(&str, &HashMap<String, LibraryDownload>)> {
        self.natives
            .as_ref()
            .and_then(|natives| natives.get(&Os::native_arch(java_arch)))
            .and_then(|natives| {
                self.downloads
                    .as_ref()
                    .and_then(|downloads| downloads.classifiers.as_ref())
                    .map(|classifiers| (natives.as_str(), classifiers))
            })
    }
}

fn default_true() -> bool {
    true
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(untagged)]
pub enum ArgumentValue {
    Single(String),
    Many(Vec<String>),
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(untagged)]
pub enum Argument {
    Normal(String),
    Ruled {
        #[serde(default)]
        rules: Vec<Rule>,
        value: ArgumentValue,
    },
}

#[derive(Serialize, Deserialize, Debug, Eq, PartialEq, Hash, Clone, Copy)]
#[serde(rename_all = "kebab-case")]
pub enum ArgumentType {
    Game,
    Jvm,
    DefaultUserJvm,
}

#[derive(Serialize, Deserialize, Debug, Eq, PartialEq, Hash, Clone)]
#[serde(rename_all = "snake_case")]
pub enum LoggingSide {
    Client,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct LogConfigDownload {
    pub id: String,
    pub sha1: String,
    pub size: u32,
    pub url: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(
    tag = "type",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase"
)]
pub enum LoggingConfiguration {
    Log4j2Xml {
        argument: String,
        file: LogConfigDownload,
    },
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct VersionInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arguments: Option<HashMap<ArgumentType, Vec<Argument>>>,
    pub asset_index: AssetIndex,
    pub assets: String,
    pub downloads: HashMap<DownloadType, Download>,
    pub id: String,
    pub java_version: Option<JavaVersion>,
    pub libraries: Vec<Library>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub logging: Option<HashMap<LoggingSide, LoggingConfiguration>>,
    pub main_class: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minecraft_arguments: Option<String>,
    #[serde(default)]
    pub minimum_launcher_version: u32,
    pub release_time: DateTime<Utc>,
    pub time: DateTime<Utc>,
    #[serde(rename = "type")]
    pub type_: VersionType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<HashMap<String, SidedDataEntry>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub processors: Option<Vec<Processor>>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Asset {
    pub hash: String,
    pub size: u32,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct AssetsIndex {
    pub objects: HashMap<String, Asset>,
}

/// Maven-style artifact path: `group:name:version[:classifier][@ext]`
/// (Forge installer extracts may use `@lzma`.)
pub fn get_path_from_artifact(artifact: &str) -> anyhow::Result<String> {
    let parts: Vec<&str> = artifact.split(':').collect();
    if parts.len() < 3 {
        anyhow::bail!("invalid maven artifact: {artifact}");
    }
    let group = parts[0].replace('.', "/");
    let name = parts[1];

    if parts.len() == 3 {
        let version_ext: Vec<&str> = parts[2].split('@').collect();
        let version = version_ext[0];
        let ext = version_ext.get(1).copied().unwrap_or("jar");
        Ok(format!("{group}/{name}/{version}/{name}-{version}.{ext}"))
    } else {
        let version = parts[2];
        let data_ext: Vec<&str> = parts[3].split('@').collect();
        let data = data_ext[0];
        let ext = data_ext.get(1).copied().unwrap_or("jar");
        Ok(format!(
            "{group}/{name}/{version}/{name}-{version}-{data}.{ext}"
        ))
    }
}

#[cfg(test)]
mod artifact_path_tests {
    use super::get_path_from_artifact;

    #[test]
    fn plain_jar() {
        assert_eq!(
            get_path_from_artifact("com.example:lib:1.0").unwrap(),
            "com/example/lib/1.0/lib-1.0.jar"
        );
    }

    #[test]
    fn classifier_jar() {
        assert_eq!(
            get_path_from_artifact("com.example:lib:1.0:natives-windows").unwrap(),
            "com/example/lib/1.0/lib-1.0-natives-windows.jar"
        );
    }

    #[test]
    fn forge_installer_extracts_lzma() {
        assert_eq!(
			get_path_from_artifact(
				"com.modrinth.daedalus:forge-installer-extracts:26.1.2-64.0.8:client@lzma"
			)
			.unwrap(),
			"com/modrinth/daedalus/forge-installer-extracts/26.1.2-64.0.8/forge-installer-extracts-26.1.2-64.0.8-client.lzma"
		);
    }

    #[test]
    fn version_with_extension() {
        assert_eq!(
            get_path_from_artifact("net.minecraft:client:1.21.5:mappings@txt").unwrap(),
            "net/minecraft/client/1.21.5/client-1.21.5-mappings.txt"
        );
    }
}
