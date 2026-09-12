use chrono::{DateTime, NaiveDateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use std::collections::HashMap;

use super::minecraft::{Argument, ArgumentType, Library, VersionInfo, VersionType};

pub const CURRENT_FABRIC_FORMAT_VERSION: usize = 0;
pub const CURRENT_FORGE_FORMAT_VERSION: usize = 0;
pub const CURRENT_QUILT_FORMAT_VERSION: usize = 1;
pub const CURRENT_NEOFORGE_FORMAT_VERSION: usize = 0;
pub const DUMMY_REPLACE_STRING: &str = "${modrinth.gameVersion}";

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct SidedDataEntry {
    pub client: String,
    pub server: String,
}

fn deserialize_date<'de, D>(deserializer: D) -> Result<DateTime<Utc>, D::Error>
where
    D: Deserializer<'de>,
{
    let s = String::deserialize(deserializer)?;
    serde_json::from_str::<DateTime<Utc>>(&format!("\"{s}\""))
        .or_else(|_| {
            NaiveDateTime::parse_from_str(&s, "%Y-%m-%dT%H:%M:%S%.f").map(|date| date.and_utc())
        })
        .map_err(serde::de::Error::custom)
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct PartialVersionInfo {
    pub id: String,
    pub inherits_from: String,
    #[serde(deserialize_with = "deserialize_date")]
    pub release_time: DateTime<Utc>,
    #[serde(deserialize_with = "deserialize_date")]
    pub time: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub main_class: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minecraft_arguments: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arguments: Option<HashMap<ArgumentType, Vec<Argument>>>,
    pub libraries: Vec<Library>,
    #[serde(rename = "type")]
    pub type_: VersionType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<HashMap<String, SidedDataEntry>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub processors: Option<Vec<Processor>>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Processor {
    pub jar: String,
    pub classpath: Vec<String>,
    pub args: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outputs: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sides: Option<Vec<String>>,
}

pub fn merge_partial_version(partial: PartialVersionInfo, merge: VersionInfo) -> VersionInfo {
    let merge_id = merge.id.clone();
    let mut libraries = vec![];

    for mut lib in merge.libraries {
        let lib_artifact = lib.name.rsplit_once(':').map(|x| x.0);
        if let Some(lib_artifact) = lib_artifact {
            if !partial.libraries.iter().any(|x| {
                let target_artifact = x.name.rsplit_once(':').map(|x| x.0);
                target_artifact == Some(lib_artifact) && x.include_in_classpath
            }) {
                libraries.push(lib);
            } else {
                lib.include_in_classpath = false;
                libraries.push(lib);
            }
        } else {
            libraries.push(lib);
        }
    }

    VersionInfo {
        arguments: if let Some(partial_args) = partial.arguments {
            if let Some(merge_args) = merge.arguments {
                let mut new_map = HashMap::new();
                fn add_keys(
                    new_map: &mut HashMap<ArgumentType, Vec<Argument>>,
                    args: HashMap<ArgumentType, Vec<Argument>>,
                ) {
                    for (type_, arguments) in args {
                        new_map.entry(type_).or_default().extend(arguments);
                    }
                }
                add_keys(&mut new_map, merge_args);
                add_keys(&mut new_map, partial_args);
                Some(new_map)
            } else {
                Some(partial_args)
            }
        } else {
            merge.arguments
        },
        asset_index: merge.asset_index,
        assets: merge.assets,
        downloads: merge.downloads,
        id: partial.id.replace(DUMMY_REPLACE_STRING, &merge_id),
        java_version: merge.java_version,
        libraries: libraries
            .into_iter()
            .chain(partial.libraries)
            .map(|mut x| {
                x.name = x.name.replace(DUMMY_REPLACE_STRING, &merge_id);
                x
            })
            .collect(),
        logging: merge.logging,
        main_class: partial.main_class.unwrap_or(merge.main_class),
        minecraft_arguments: partial.minecraft_arguments,
        minimum_launcher_version: merge.minimum_launcher_version,
        release_time: partial.release_time,
        time: partial.time,
        type_: partial.type_,
        data: partial.data,
        processors: partial.processors,
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub game_versions: Vec<LoaderGameVersion>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct LoaderGameVersion {
    pub id: String,
    pub stable: bool,
    pub loaders: Vec<LoaderVersion>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct LoaderVersion {
    pub id: String,
    pub url: String,
    pub stable: bool,
}

pub fn loader_meta_path(loader: &str) -> String {
    let format_version = match loader {
        "fabric" => CURRENT_FABRIC_FORMAT_VERSION,
        "forge" => CURRENT_FORGE_FORMAT_VERSION,
        "quilt" => CURRENT_QUILT_FORMAT_VERSION,
        "neo" => CURRENT_NEOFORGE_FORMAT_VERSION,
        _ => 0,
    };
    format!("{loader}/v{format_version}/manifest.json")
}
