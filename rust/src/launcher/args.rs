use anyhow::{anyhow, Result};
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::RwLock;

use crate::meta::minecraft::{
    get_path_from_artifact, Argument, ArgumentType, ArgumentValue, Library, LoggingConfiguration,
    LoggingSide, VersionInfo,
};
use crate::state::models::Account;

use super::dirs;
use super::download::client_jar_path;
use super::quick_play_version::{
    QuickPlayServerVersion, QuickPlaySingleplayerVersion, QuickPlayVersion,
};
use super::rules::{parse_rules, RuleFeatures};
use super::theseus::{self, LAUNCHER_ENTRY};

const TEMPORARY_REPLACE_CHAR: &str = "\n";
static CLASSPATH_CACHE: Lazy<RwLock<HashMap<String, String>>> =
    Lazy::new(|| RwLock::new(HashMap::new()));

pub struct LaunchAuth {
    pub username: String,
    pub uuid: String,
    pub access_token: String,
    pub user_type: String,
}

impl From<&Account> for LaunchAuth {
    fn from(a: &Account) -> Self {
        Self {
            username: a.username.clone(),
            uuid: a.uuid.replace('-', ""),
            access_token: a.access_token.clone().unwrap_or_else(|| "0".into()),
            user_type: match a.kind.as_str() {
                "msa" => "msa",
                "yggdrasil" => "mojang",
                _ => "legacy",
            }
            .into(),
        }
    }
}

pub struct LaunchArgs {
    pub java: PathBuf,
    pub jvm_args: Vec<String>,
    pub entry_class: String,
    pub minecraft_main_class: String,
    pub game_args: Vec<String>,
    pub cwd: PathBuf,
    pub env: Vec<(String, String)>,
    pub wrapper_command: Option<String>,
    pub post_exit_command: Option<String>,
}

pub fn required_java_major(info: &VersionInfo) -> u32 {
    info.java_version
        .as_ref()
        .map(|j| j.major_version)
        .unwrap_or(8)
}

pub fn build_launch_args(
    resource_dir: &str,
    instance_path: &str,
    version_jar_id: &str,
    info: &VersionInfo,
    auth: &LaunchAuth,
    java: PathBuf,
    java_arch: &str,
    java_major: u32,
    memory_mb: u32,
    resolution: (u32, u32),
    extra_jvm_args: &[String],
    quick_play_singleplayer: Option<&str>,
    quick_play_multiplayer: Option<&str>,
    quick_play_server_endpoint: Option<(String, u16)>,
    quick_play_version: QuickPlayVersion,
    rpc_addr: SocketAddr,
) -> Result<LaunchArgs> {
    let cwd = dirs::instance_dir(resource_dir, instance_path);
    let natives = dirs::natives(resource_dir, version_jar_id);
    let assets = dirs::assets(resource_dir);
    // Legacy flat resources live in meta/resources; 1.6.x --assetsDir uses ${game_assets}.
    let game_assets = if info.assets == "legacy" {
        dirs::legacy_assets(resource_dir)
    } else {
        assets.clone()
    };
    let libraries = dirs::libraries(resource_dir);
    let theseus_jar = theseus::jar_path_string(resource_dir)?;
    let classpath = get_classpath(
        resource_dir,
        version_jar_id,
        &info.libraries,
        java_arch,
        &theseus_jar,
    )?;

    // Empty / whitespace must not enable Quick Play — MC may treat
    // `--quickPlaySingleplayer ""` as "open first world".
    let quick_play_world = quick_play_singleplayer
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let quick_play_server = quick_play_multiplayer
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let supports_quick_play_sp = quick_play_world.is_some()
        && quick_play_version.singleplayer == QuickPlaySingleplayerVersion::Builtin;
    let supports_quick_play_mp = quick_play_server.is_some()
        && matches!(
            quick_play_version.server,
            QuickPlayServerVersion::Builtin
                | QuickPlayServerVersion::BuiltinLegacy
                | QuickPlayServerVersion::Injected
        );

    let features = RuleFeatures {
        has_custom_resolution: true,
        has_quick_plays_support: supports_quick_play_sp || supports_quick_play_mp,
        is_quick_play_singleplayer: supports_quick_play_sp,
        is_quick_play_multiplayer: supports_quick_play_mp
            && quick_play_version.server == QuickPlayServerVersion::Builtin,
        ..Default::default()
    };

    let mut jvm_args = Vec::new();

    if let Some(args) = info
        .arguments
        .as_ref()
        .and_then(|m| m.get(&ArgumentType::Jvm))
    {
        for arg in args {
            jvm_args.extend(expand_argument(arg, java_arch, features, |s| {
                parse_jvm_placeholder(s, &natives, &libraries, &classpath, version_jar_id)
            }));
        }
    } else {
        jvm_args.push(format!("-Djava.library.path={}", natives.display()));
        jvm_args.push(format!("-Djna.tmpdir={}", natives.display()));
        jvm_args.push(format!(
            "-Dorg.lwjgl.system.SharedLibraryExtractPath={}",
            natives.display()
        ));
        jvm_args.push(format!("-Dio.netty.native.workdir={}", natives.display()));
        jvm_args.push("-Dminecraft.launcher.brand=aml".into());
        jvm_args.push("-Dminecraft.launcher.version=0.1".into());
        jvm_args.push("-cp".into());
        jvm_args.push(classpath.clone());
    }

    jvm_args.push(format!("-Xmx{memory_mb}M"));

    if let Some(logging) = &info.logging {
        if let Some(LoggingConfiguration::Log4j2Xml { argument, file }) =
            logging.get(&LoggingSide::Client)
        {
            let path = dirs::log_configs(resource_dir).join(&file.id);
            jvm_args.push(argument.replace("${path}", &path.to_string_lossy()));
        }
    }

    jvm_args.push(format!("-javaagent:{theseus_jar}"));
    jvm_args.push(format!("-Dmodrinth.internal.ipc.host={}", rpc_addr.ip()));
    jvm_args.push(format!("-Dmodrinth.internal.ipc.port={}", rpc_addr.port()));
    jvm_args.push(format!(
        "-Dmodrinth.internal.quickPlay.serverVersion={}",
        quick_play_server_json(quick_play_version)
    ));
    if supports_quick_play_mp
        && quick_play_version.server == QuickPlayServerVersion::Injected
    {
        if let Some((host, port)) = &quick_play_server_endpoint {
            jvm_args.push(format!("-Dmodrinth.internal.quickPlay.host={host}"));
            jvm_args.push(format!("-Dmodrinth.internal.quickPlay.port={port}"));
        }
    }

    if java_major >= 9 {
        jvm_args.push("--add-opens=java.base/java.lang.reflect=ALL-UNNAMED".into());
    }
    if java_major >= 25 {
        jvm_args.push("--add-opens=jdk.internal/jdk.internal.misc=ALL-UNNAMED".into());
    }

    if !jvm_args.iter().any(|a| a == "-cp" || a == "-classpath") {
        jvm_args.push("-cp".into());
        jvm_args.push(classpath.clone());
    }

    jvm_args.extend(extra_jvm_args.iter().cloned());

    let mut game_args = Vec::new();
    if let Some(args_map) = &info.arguments {
        if let Some(args) = args_map.get(&ArgumentType::Game) {
            for arg in args {
                game_args.extend(expand_argument(arg, java_arch, features, |s| {
                    parse_game_placeholder(
                        s,
                        auth,
                        &cwd,
                        &assets,
                        &game_assets,
                        info,
                        version_jar_id,
                        resolution,
                        quick_play_world,
                        quick_play_server,
                    )
                }));
            }
        }
    } else if let Some(legacy) = &info.minecraft_arguments {
        for token in legacy.split(' ') {
            if token.is_empty() {
                continue;
            }
            game_args.push(parse_game_placeholder(
                &token.replace(' ', TEMPORARY_REPLACE_CHAR),
                auth,
                &cwd,
                &assets,
                &game_assets,
                info,
                version_jar_id,
                resolution,
                None,
                None,
            ));
        }
    } else {
        return Err(anyhow!("version has no game arguments"));
    }

    if !supports_quick_play_sp && !supports_quick_play_mp {
        // Loader/version JSON may still emit these; strip so plain launches
        // land on the title screen instead of a world.
        strip_flag_and_value(&mut game_args, "--quickPlaySingleplayer");
        strip_flag_and_value(&mut game_args, "--quickPlayMultiplayer");
        strip_flag_and_value(&mut game_args, "--quickPlayRealms");
        strip_flag_and_value(&mut game_args, "--server");
        strip_flag_and_value(&mut game_args, "--port");
    } else if supports_quick_play_sp {
        if let Some(world) = quick_play_world {
            if !game_args
                .iter()
                .any(|a| a.contains("quickPlaySingleplayer"))
            {
                game_args.push("--quickPlaySingleplayer".into());
                game_args.push(world.to_string());
            }
        }
    } else if supports_quick_play_mp {
        match quick_play_version.server {
            QuickPlayServerVersion::Builtin => {
                if let Some(addr) = quick_play_server {
                    if !game_args.iter().any(|a| a.contains("quickPlayMultiplayer")) {
                        game_args.push("--quickPlayMultiplayer".into());
                        game_args.push(addr.to_string());
                    }
                }
            }
            QuickPlayServerVersion::BuiltinLegacy => {
                if let Some((host, port)) = &quick_play_server_endpoint {
                    strip_flag_and_value(&mut game_args, "--quickPlayMultiplayer");
                    game_args.push("--server".into());
                    game_args.push(host.clone());
                    game_args.push("--port".into());
                    game_args.push(port.to_string());
                }
            }
            QuickPlayServerVersion::Injected | QuickPlayServerVersion::Unsupported => {
                strip_flag_and_value(&mut game_args, "--quickPlayMultiplayer");
            }
        }
    }

    Ok(LaunchArgs {
        java,
        jvm_args,
        entry_class: LAUNCHER_ENTRY.into(),
        minecraft_main_class: info.main_class.clone(),
        game_args,
        cwd,
        env: vec![],
        wrapper_command: None,
        post_exit_command: None,
    })
}

/// Remove `--flag` and the following value token (if present).
fn strip_flag_and_value(args: &mut Vec<String>, flag: &str) {
    let mut i = 0;
    while i < args.len() {
        if args[i] == flag || args[i].starts_with(&format!("{flag}=")) {
            args.remove(i);
            if i < args.len()
                && !args[i].starts_with('-')
                && !args[i].starts_with("--")
            {
                args.remove(i);
            }
        } else {
            i += 1;
        }
    }
}

fn quick_play_server_json(version: QuickPlayVersion) -> &'static str {
    use super::quick_play_version::QuickPlayServerVersion;
    match version.server {
        QuickPlayServerVersion::Builtin => "BUILTIN",
        QuickPlayServerVersion::BuiltinLegacy => "BUILTIN_LEGACY",
        QuickPlayServerVersion::Injected => "INJECTED",
        QuickPlayServerVersion::Unsupported => "UNSUPPORTED",
    }
}

fn expand_argument(
    arg: &Argument,
    java_arch: &str,
    features: RuleFeatures,
    map: impl Fn(&str) -> String,
) -> Vec<String> {
    match arg {
        Argument::Normal(s) => vec![map(s)],
        Argument::Ruled { rules, value } => {
            if !parse_rules(rules, java_arch, features) {
                return vec![];
            }
            match value {
                ArgumentValue::Single(s) => vec![map(s)],
                ArgumentValue::Many(many) => many.iter().map(|s| map(s)).collect(),
            }
        }
    }
}

fn parse_jvm_placeholder(
    s: &str,
    natives: &PathBuf,
    libraries: &PathBuf,
    classpath: &str,
    version_name: &str,
) -> String {
    let mut argument = s.to_string();
    argument.retain(|c| !c.is_whitespace());
    argument
        .replace("${natives_directory}", &natives.to_string_lossy())
        .replace("${library_directory}", &libraries.to_string_lossy())
        .replace("${classpath_separator}", classpath_separator())
        .replace("${launcher_name}", "aml")
        .replace("${launcher_version}", "0.1")
        .replace("${version_name}", version_name)
        .replace("${classpath}", classpath)
}

fn parse_game_placeholder(
    s: &str,
    auth: &LaunchAuth,
    game_dir: &PathBuf,
    assets_root: &PathBuf,
    game_assets: &PathBuf,
    info: &VersionInfo,
    version_name: &str,
    resolution: (u32, u32),
    quick_play_singleplayer: Option<&str>,
    quick_play_multiplayer: Option<&str>,
) -> String {
    s.replace("${auth_player_name}", &auth.username)
        .replace("${auth_uuid}", &auth.uuid)
        .replace("${auth_access_token}", &auth.access_token)
        .replace("${accessToken}", &auth.access_token)
        .replace("${auth_session}", &auth.access_token)
        .replace("${user_type}", &auth.user_type)
        .replace("${version_name}", version_name)
        .replace("${game_directory}", &game_dir.to_string_lossy())
        .replace("${assets_root}", &assets_root.to_string_lossy())
        .replace("${game_assets}", &game_assets.to_string_lossy())
        .replace("${assets_index_name}", &info.asset_index.id)
        .replace("${version_type}", info.type_.as_str())
        .replace("${user_properties}", "{}")
        .replace("${clientid}", "c4502edb-87c6-40cb-b595-64a280cf8906")
        .replace("${auth_xuid}", "0")
        .replace("${resolution_width}", &resolution.0.to_string())
        .replace("${resolution_height}", &resolution.1.to_string())
        .replace(
            "${quickPlaySingleplayer}",
            quick_play_singleplayer.unwrap_or(""),
        )
        .replace(
            "${quickPlayMultiplayer}",
            quick_play_multiplayer.unwrap_or(""),
        )
        .replace("${quickPlayRealms}", "")
        .replace(TEMPORARY_REPLACE_CHAR, " ")
}

pub fn classpath_separator() -> &'static str {
    if cfg!(windows) {
        ";"
    } else {
        ":"
    }
}

pub fn get_classpath(
    resource_dir: &str,
    version_jar_id: &str,
    libraries: &[Library],
    java_arch: &str,
    theseus_jar: &str,
) -> Result<String> {
    let cache_key = format!("{resource_dir}\0{version_jar_id}\0{java_arch}\0{theseus_jar}");
    if let Some(classpath) = CLASSPATH_CACHE
        .read()
        .ok()
        .and_then(|cache| cache.get(&cache_key).cloned())
    {
        return Ok(classpath);
    }

    let mut entries = Vec::new();
    entries.push(theseus_jar.to_string());
    entries.push(
        client_jar_path(resource_dir, version_jar_id)
            .to_string_lossy()
            .to_string(),
    );

    let libs_root = dirs::libraries(resource_dir);
    for lib in libraries {
        if !lib.include_in_classpath {
            continue;
        }
        if !parse_rules(
            lib.rules.as_deref().unwrap_or(&[]),
            java_arch,
            RuleFeatures::default(),
        ) {
            continue;
        }
        if lib.natives.is_some()
            && lib
                .downloads
                .as_ref()
                .and_then(|d| d.artifact.as_ref())
                .is_none()
        {
            continue;
        }
        let rel = if let Some(path) = lib
            .downloads
            .as_ref()
            .and_then(|d| d.artifact.as_ref())
            .and_then(|a| a.path.clone())
        {
            path
        } else {
            get_path_from_artifact(&lib.name)?
        };
        entries.push(libs_root.join(rel).to_string_lossy().to_string());
    }

    let classpath = entries.join(classpath_separator());
    if let Ok(mut cache) = CLASSPATH_CACHE.write() {
        cache.insert(cache_key, classpath.clone());
    }
    Ok(classpath)
}

pub fn processor_classpath(resource_dir: &str, jars: &[String]) -> Result<String> {
    let libs = dirs::libraries(resource_dir);
    let mut entries = Vec::new();
    for jar in jars {
        entries.push(
            libs.join(get_path_from_artifact(jar)?)
                .to_string_lossy()
                .to_string(),
        );
    }
    Ok(entries.join(classpath_separator()))
}
