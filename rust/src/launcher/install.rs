use anyhow::{anyhow, Context, Result};
use std::collections::HashMap;
use std::process::Stdio;
use std::time::Instant;
use tokio::process::Command;

use crate::meta::minecraft::{get_path_from_artifact, VersionInfo};
use crate::meta::modded::Processor;
use crate::state::db;
use crate::state::models::{InstallStage, Instance, ModLoader};
use crate::state::{resource_dir, try_state};

use super::dirs;
use super::download::{self, ProgressFn};
use super::manifest;
use super::progress;

pub async fn install_instance(
    instance_id: &str,
    java_path: Option<String>,
    force: bool,
    on_progress: Option<ProgressFn>,
) -> Result<Instance> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let mut instance = db::get_instance(&state.pool, instance_id).await?;

    db::set_install_stage(&state.pool, instance_id, InstallStage::Installing).await?;
    dirs::ensure_instance_dir(&resource, &instance.path).await?;

    let report = |p: f64, msg: String| {
        if let Some(cb) = &on_progress {
            cb(p, msg);
        }
    };

    let loader = ModLoader::parse(&instance.loader);
    report(0.02, "Resolving version metadata…".into());

    let (info, version_jar_id) = manifest::resolve_version_info(
        &resource,
        &instance.game_version,
        &loader,
        instance.loader_version.as_deref(),
    )
    .await?;

    // Persist resolved loader version id
    if !matches!(loader, ModLoader::Vanilla) {
        if let Some(lv) = version_jar_id
            .strip_prefix(&format!("{}-", instance.game_version))
            .map(|s| s.to_string())
        {
            instance = db::update_instance(
                &state.pool,
                instance_id,
                None,
                None,
                None,
                None,
                Some(Some(lv)),
            )
            .await?;
        }
    }

    let java_arch = std::env::consts::ARCH;

    report(0.08, "Downloading Minecraft files…".into());
    if force {
        // Force re-download by removing client jar marker is enough; download checks sha1
    }
    download::download_minecraft(
        &resource,
        &info,
        &version_jar_id,
        java_arch,
        progress::nest_progress(
            on_progress.clone(),
            0.08,
            0.92,
            "Downloading Minecraft files",
        ),
    )
    .await?;

    if let Some(processors) = &info.processors {
        report(0.92, "Running loader processors…".into());
        let java = java_path
            .or(instance.java_path.clone())
            .ok_or_else(|| anyhow!("java path required for Forge processors"))?;
        run_processors(
            &resource,
            &instance.path,
            &info,
            processors,
            &java,
            &version_jar_id,
        )
        .await?;
    }

    db::set_install_stage(&state.pool, instance_id, InstallStage::Installed).await?;
    report(1.0, "Install complete".into());
    db::get_instance(&state.pool, instance_id).await
}

pub async fn run_processors(
    resource_dir: &str,
    instance_path: &str,
    info: &VersionInfo,
    processors: &[Processor],
    java_path: &str,
    version_jar_id: &str,
) -> Result<()> {
    let java = dirs::java_executable(java_path)?;
    let instance_dir = dirs::instance_dir(resource_dir, instance_path);
    let libraries = dirs::libraries(resource_dir);
    let client_jar = download::client_jar_path(resource_dir, version_jar_id);

    // Only values that come FROM install_profile.json may be run through the
    // "[maven:coord]" / "/relative-to-resource-dir" / "'literal'" grammar. Paths
    // AML computes itself are already absolute and must be substituted verbatim:
    // feeding them to the resolver makes "/home/yz/…" indistinguishable from
    // Forge's "/data/client.lzma" and prepends the resource dir a second time.
    // Windows hid this because "C:\…" never starts with '/'.
    let mut forge_data: HashMap<String, String> = HashMap::new();
    if let Some(data) = &info.data {
        for (k, v) in data {
            forge_data.insert(k.clone(), resolve_data_value(&v.client, resource_dir)?);
        }
    }
    let mut computed: HashMap<String, String> = HashMap::new();
    computed.insert("SIDE".into(), "client".into());
    computed.insert(
        "MINECRAFT_JAR".into(),
        client_jar.to_string_lossy().into_owned(),
    );
    computed.insert("ROOT".into(), instance_dir.to_string_lossy().into_owned());
    computed.insert(
        "LIBRARY_DIR".into(),
        libraries.to_string_lossy().into_owned(),
    );

    for processor in processors {
        if let Some(sides) = &processor.sides {
            if !sides.iter().any(|s| s == "client") {
                continue;
            }
        }

        let mut classpath = vec![processor.jar.clone()];
        classpath.extend(processor.classpath.clone());
        let cp = super::args::processor_classpath(resource_dir, &classpath)?;

        let main_class =
            read_jar_main_class(&libraries.join(get_path_from_artifact(&processor.jar)?))?;

        let args: Vec<String> = processor
            .args
            .iter()
            .map(|a| substitute_processor_arg(a, &forge_data, &computed, resource_dir))
            .collect::<Result<Vec<_>>>()?;

        let mut command = Command::new(&java);
        command
            .arg("-cp")
            .arg(&cp)
            .arg(&main_class)
            .args(&args)
            .current_dir(&instance_dir)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        super::win_process::hide_console_window(&mut command);
        let status = command
            .status()
            .await
            .with_context(|| format!("run processor {}", processor.jar))?;

        if !status.success() {
            anyhow::bail!("processor {} failed with {status}", processor.jar);
        }
    }
    Ok(())
}

/// Resolve one install_profile.json `data` value to an absolute path or literal.
fn resolve_data_value(value: &str, resource_dir: &str) -> Result<String> {
    if let Some(artifact) = value.strip_prefix('[').and_then(|v| v.strip_suffix(']')) {
        return Ok(dirs::libraries(resource_dir)
            .join(get_path_from_artifact(artifact)?)
            .to_string_lossy()
            .into_owned());
    }
    if let Some(relative) = value.strip_prefix('/') {
        return Ok(std::path::Path::new(resource_dir)
            .join(relative)
            .to_string_lossy()
            .into_owned());
    }
    // 'quoted' entries such as MC_SLIM_SHA carry their quotes in the json; Forge drops them.
    Ok(value
        .strip_prefix('\'')
        .and_then(|v| v.strip_suffix('\''))
        .unwrap_or(value)
        .to_string())
}

fn substitute_processor_arg(
    arg: &str,
    forge_data: &HashMap<String, String>,
    computed: &HashMap<String, String>,
    resource_dir: &str,
) -> Result<String> {
    let mut out = arg.to_string();
    // {KEY} replacements — both maps already hold final values, so nothing here
    // may be re-interpreted as a relative or maven path.
    for (k, v) in forge_data.iter().chain(computed.iter()) {
        let token = format!("{{{k}}}");
        if out.contains(&token) {
            out = out.replace(&token, v);
        }
    }
    // [maven:coord] written directly in the processor args
    if out.starts_with('[') && out.ends_with(']') {
        let artifact = &out[1..out.len() - 1];
        out = dirs::libraries(resource_dir)
            .join(get_path_from_artifact(artifact)?)
            .to_string_lossy()
            .to_string();
    }
    Ok(out)
}

fn read_jar_main_class(jar: &std::path::Path) -> Result<String> {
    let file = std::fs::File::open(jar)
        .with_context(|| format!("open processor jar {}", jar.display()))?;
    let mut archive = zip::ZipArchive::new(file)?;
    let mut manifest = archive
        .by_name("META-INF/MANIFEST.MF")
        .context("processor jar missing MANIFEST.MF")?;
    let mut contents = String::new();
    std::io::Read::read_to_string(&mut manifest, &mut contents)?;
    for line in contents.lines() {
        if let Some(rest) = line.strip_prefix("Main-Class:") {
            return Ok(rest.trim().to_string());
        }
    }
    Err(anyhow!("Main-Class not found in {}", jar.display()))
}

pub async fn ensure_valid_game_version(
    pool: &sqlx::SqlitePool,
    resource: &str,
    instance: &mut Instance,
) -> Result<()> {
    let re_mc = regex::Regex::new(r"\b1\.\d+(?:\.\d+)?\b").unwrap();
    if re_mc.is_match(&instance.game_version) {
        return Ok(());
    }

    let mut detected_version: Option<String> = None;
    let mut detected_loader: Option<String> = None;
    let mut detected_loader_version: Option<String> = None;

    let base_versions_dir = dirs::versions(resource);
    let candidates = [
        base_versions_dir.join(&instance.path).join(format!("{}.json", instance.path)),
        base_versions_dir.join(&instance.game_version).join(format!("{}.json", instance.game_version)),
        dirs::instance_dir(resource, &instance.path).join(format!("{}.json", instance.path)),
    ];

    for candidate in candidates {
        if candidate.exists() {
            if let Ok(text) = tokio::fs::read_to_string(&candidate).await {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                    if let Some(patches) = v.get("patches").and_then(|p| p.as_array()) {
                        for patch in patches {
                            let pid = patch.get("id").and_then(|s| s.as_str()).unwrap_or("");
                            let pver = patch.get("version").and_then(|s| s.as_str()).unwrap_or("");
                            let pinherits = patch.get("inheritsFrom").and_then(|s| s.as_str()).unwrap_or("");
                            if (pid == "game" || pid == "minecraft") && re_mc.is_match(pver) {
                                detected_version = re_mc.find(pver).map(|m| m.as_str().to_string());
                            }
                            if detected_version.is_none() && re_mc.is_match(pinherits) {
                                detected_version = re_mc.find(pinherits).map(|m| m.as_str().to_string());
                            }
                            if pid == "forge" {
                                detected_loader = Some("forge".to_string());
                                if let Some(m) = re_mc.find(pver) {
                                    if detected_version.is_none() {
                                        detected_version = Some(m.as_str().to_string());
                                    }
                                }
                                if let Some(caps) = regex::Regex::new(r"forge[-:]?(\d+(?:\.\d+)+)").ok().and_then(|r| r.captures(pver)) {
                                    detected_loader_version = caps.get(1).map(|m| m.as_str().to_string());
                                }
                            }
                        }
                    }
                    if detected_version.is_none() {
                        if let Some(inherits) = v.get("inheritsFrom").and_then(|s| s.as_str()) {
                            if let Some(m) = re_mc.find(inherits) {
                                detected_version = Some(m.as_str().to_string());
                            }
                        }
                    }
                    if detected_version.is_none() {
                        if let Some(client_ver) = v.get("clientVersion").and_then(|s| s.as_str()) {
                            if let Some(m) = re_mc.find(client_ver) {
                                detected_version = Some(m.as_str().to_string());
                            }
                        }
                    }
                    if detected_version.is_none() {
                        if let Some(libs) = v.get("libraries").and_then(|l| l.as_array()) {
                            for lib in libs {
                                let name = lib.get("name").and_then(|s| s.as_str()).unwrap_or("");
                                if name.contains("net.minecraftforge:forge:") || name.contains("net.minecraftforge:fmlearlydisplay:") {
                                    if let Some(m) = re_mc.find(name) {
                                        detected_version = Some(m.as_str().to_string());
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if detected_version.is_none() {
                        if let Some(m) = re_mc.find(&text) {
                            detected_version = Some(m.as_str().to_string());
                        }
                    }
                }
            }
        }
        if detected_version.is_some() {
            break;
        }
    }

    if detected_version.is_none() {
        if let Some(lv) = instance.loader_version.as_deref() {
            if lv.starts_with("47.") {
                detected_version = Some("1.20.1".to_string());
            } else if lv.starts_with("14.23.5.") {
                detected_version = Some("1.12.2".to_string());
            } else if lv.starts_with("36.") {
                detected_version = Some("1.16.5".to_string());
            } else if lv.starts_with("40.") {
                detected_version = Some("1.18.2".to_string());
            } else if lv.starts_with("43.") {
                detected_version = Some("1.19.2".to_string());
            } else if lv.starts_with("48.") {
                detected_version = Some("1.20.2".to_string());
            } else if lv.starts_with("49.") {
                detected_version = Some("1.20.4".to_string());
            } else if lv.starts_with("50.") {
                detected_version = Some("1.20.6".to_string());
            } else if lv.starts_with("51.") {
                detected_version = Some("1.21".to_string());
            }
        }
    }

    if let Some(real_ver) = detected_version {
        let lv = detected_loader_version.or_else(|| instance.loader_version.clone());
        let ldr = detected_loader.unwrap_or_else(|| instance.loader.clone());

        let _ = sqlx::query(
            "UPDATE instances SET game_version = ?, loader = ?, loader_version = ? WHERE id = ?"
        )
        .bind(&real_ver)
        .bind(&ldr)
        .bind(&lv)
        .bind(&instance.id)
        .execute(pool)
        .await;

        instance.game_version = real_ver;
        instance.loader = ldr;
        instance.loader_version = lv;
    }

    Ok(())
}

pub async fn launch_instance(
    instance_id: &str,
    java_path: String,
    quick_play_singleplayer: Option<String>,
    quick_play_multiplayer: Option<String>,
) -> Result<super::process::ProcessMetadata> {
    let launch_started = Instant::now();
    let state = try_state()?;
    let resource = resource_dir().await?;
    let mut instance = db::get_instance(&state.pool, instance_id).await?;
    ensure_valid_game_version(&state.pool, &resource, &mut instance).await?;
    if instance.install_stage != InstallStage::Installed.as_str() {
        let root = dirs::instance_dir(&resource, &instance.path);
        if root.exists() {
            let _ = db::set_install_stage(&state.pool, instance_id, InstallStage::Installed).await;
        } else {
            anyhow::bail!("instance is not installed");
        }
    }

    let account = db::get_active_account(&state.pool)
        .await?
        .ok_or_else(|| anyhow!("no active account; create an offline account first"))?;

    let loader = ModLoader::parse(&instance.loader);
    let version_jar_id = if matches!(loader, ModLoader::Vanilla) {
        instance.game_version.clone()
    } else {
        format!(
            "{}-{}",
            instance.game_version,
            instance
                .loader_version
                .as_deref()
                .unwrap_or("unknown")
        )
    };

    let info = match manifest::load_cached_version_info(&resource, &version_jar_id).await {
        Ok(info) => info,
        Err(_) => match manifest::load_cached_version_info(&resource, &instance.path).await {
            Ok(info) => info,
            Err(_) => {
                let (info, _) = manifest::resolve_version_info(
                    &resource,
                    &instance.game_version,
                    &loader,
                    instance.loader_version.as_deref(),
                )
                .await?;
                info
            }
        },
    };
    let required_major = super::args::required_java_major(&info);
    let java_arch = std::env::consts::ARCH;

    let configured = instance
        .java_path
        .clone()
        .filter(|p| !p.trim().is_empty())
        .unwrap_or(java_path);
    let java_exe = dirs::java_executable(&configured)?;

    let java_check_started = Instant::now();
    let detected = crate::api::java_download::check_jre(java_exe.to_string_lossy().to_string())
        .await
        .ok_or_else(|| {
            anyhow!(
                "无法读取 Java 版本: {}（请确认路径指向 java.exe）",
                java_exe.display()
            )
        })?;
    let java_check_ms = java_check_started.elapsed().as_millis();
    if (detected.major_version as u32) < required_major {
        anyhow::bail!(
			"此 Minecraft 版本需要 Java {}（元数据 javaVersion.majorVersion），当前为 Java {}（{}）。请在设置中安装/配置 Java {}。",
			required_major,
			detected.major_version,
			java_exe.display(),
			required_major
		);
    }

    let defaults = db::get_launch_defaults(&state.pool)
        .await
        .unwrap_or_default();
    // Instance override → global defaults.
    let memory = instance
        .memory_mb
        .unwrap_or(defaults.memory_mb)
        .clamp(512, 131_072) as u32;
    // 空白覆盖不应遮蔽全局默认参数；shell_words 支持引号包裹含空格的值。
    let extra_source = instance
        .extra_jvm_args
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .or(defaults.extra_jvm_args.as_deref())
        .unwrap_or("");
    let extra: Vec<String> = shell_words::split(extra_source).unwrap_or_else(|_| {
        extra_source
            .split_whitespace()
            .map(str::to_string)
            .collect()
    });

    let auth = super::args::LaunchAuth::from(&account);
    dirs::ensure_instance_dir(&resource, &instance.path).await?;

    let manifest_started = Instant::now();
    let mc_manifest = match manifest::load_cached_minecraft_manifest(&resource).await {
        Ok(manifest) => manifest,
        Err(_) => manifest::fetch_minecraft_manifest(&resource).await?,
    };
    let version_index = manifest::version_index_in_manifest(&mc_manifest, &instance.game_version)?;
    let quick_play_version = super::quick_play_version::QuickPlayVersion::find_version(
        version_index,
        &mc_manifest.versions,
    );
    let manifest_ms = manifest_started.elapsed().as_millis();

    // Modern MC extracts natives into these subdirs at runtime.
    let natives_root = dirs::natives(&resource, &version_jar_id);
    for sub in ["java", "jna", "lwjgl", "netty"] {
        tokio::fs::create_dir_all(natives_root.join(sub)).await?;
    }

    let rpc_server = super::rpc::RpcServerBuilder::new().launch().await?;
    let authlib_injector = if account.kind == "yggdrasil" {
        let service_id = account
            .auth_server_id
            .as_deref()
            .ok_or_else(|| anyhow!("外置账号缺少验证服务器配置"))?;
        let service = db::get_yggdrasil_service(&state.pool, service_id).await?;
        let api_url = super::auth::normalize_yggdrasil_api_url(&service.api_url)?;
        let jar = super::authlib_injector::ensure_authlib_injector(&resource).await?;
        Some((jar, api_url))
    } else {
        None
    };

    let args_started = Instant::now();
    let xml_logging = info
        .logging
        .as_ref()
        .and_then(|logging| logging.get(&crate::meta::LoggingSide::Client))
        .is_some();
    let resolution = (
        instance
            .window_width
            .unwrap_or(defaults.window_width)
            .clamp(320, 16_384) as u32,
        instance
            .window_height
            .unwrap_or(defaults.window_height)
            .clamp(320, 16_384) as u32,
    );
    let fullscreen = instance.fullscreen.unwrap_or(defaults.fullscreen);
    let mut server_endpoint = None;
    if let Some(addr) = quick_play_multiplayer
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        match quick_play_version.server {
            super::quick_play_version::QuickPlayServerVersion::BuiltinLegacy
            | super::quick_play_version::QuickPlayServerVersion::Injected => {
                let (host, port) = super::server_address::parse_server_address(addr)?;
                server_endpoint = Some(
                    super::server_address::resolve_server_address(&host, port).await?,
                );
            }
            _ => {}
        }
    }
    let quick_play = super::quick_play_version::QuickPlayOptions {
        singleplayer: quick_play_singleplayer.as_deref(),
        multiplayer: quick_play_multiplayer.as_deref(),
        server_endpoint,
        version: quick_play_version,
    };
    let mut args = super::args::build_launch_args(
        &resource,
        &instance.path,
        &version_jar_id,
        &info,
        &auth,
        java_exe,
        java_arch,
        detected.major_version as u32,
        memory,
        resolution,
        &extra,
        &quick_play,
        rpc_server.address(),
    )?;
    if fullscreen
        && !args
            .game_args
            .iter()
            .any(|argument| argument == "--fullscreen")
    {
        args.game_args.push("--fullscreen".into());
    }
    let mut env_map: HashMap<String, String> = HashMap::new();
    #[cfg(target_os = "linux")]
    {
        // On Linux under Wayland (especially with NVIDIA), Minecraft's LWJGL GLFW
        // crashes in glfwCreateWindow (SIGSEGV) when attempting native Wayland without proper decorations.
        // Forcing XWayland via GLFW_PLATFORM=x11 ensures rock-solid window creation.
        if std::env::var("WAYLAND_DISPLAY").is_ok() {
            env_map.insert("GLFW_PLATFORM".to_string(), "x11".to_string());
        }
    }

    let environment = instance
        .environment_vars
        .as_deref()
        .or(defaults.environment_vars.as_deref())
        .filter(|value| !value.trim().is_empty());
    if let Some(environment) = environment {
        let values: HashMap<String, String> =
            serde_json::from_str(environment).context("环境变量配置不是有效的 JSON 对象")?;
        for (k, v) in values {
            env_map.insert(k, v);
        }
    }
    args.env = env_map.into_iter().collect();
    args.wrapper_command = instance
        .wrapper_command
        .clone()
        .or(defaults.wrapper_command.clone());
    args.post_exit_command = instance
        .post_exit_command
        .clone()
        .or(defaults.post_exit_command.clone());
    if let Some((jar, api_url)) = authlib_injector {
        let injector_arg = format!("-javaagent:{}={api_url}", jar.to_string_lossy());
        let first_agent = args
            .jvm_args
            .iter()
            .position(|argument| argument.starts_with("-javaagent:"))
            .unwrap_or(args.jvm_args.len());
        args.jvm_args.insert(first_agent, injector_arg);
    }
    let args_ms = args_started.elapsed().as_millis();

    // Apply Minecraft language (and similar) via options.txt before spawn.
    if let Some(lang) = defaults
        .game_language
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        let options_path = dirs::instance_dir(&resource, &instance.path).join("options.txt");
        super::options_txt::upsert_options_txt(&options_path, &[("lang", lang)])
            .await
            .with_context(|| format!("写入游戏语言到 {}", options_path.display()))?;
    }

    let log_path = dirs::instance_dir(&resource, &instance.path)
        .join("logs")
        .join("launcher_log.txt");

    let spawn_started = Instant::now();
    let pre_launch = instance
        .pre_launch_command
        .as_deref()
        .or(defaults.pre_launch_command.as_deref())
        .filter(|value| !value.trim().is_empty());
    if let Some(command) = pre_launch {
        super::process::run_hook(command, &args.cwd, &args.env)
            .await
            .context("启动前命令失败")?;
    }
    let meta = super::process::PROCESS_MANAGER
        .spawn(
            instance_id,
            args,
            log_path,
            rpc_server,
            &instance.name,
            xml_logging,
            quick_play_singleplayer.clone(),
        )
        .await?;
    let spawn_ms = spawn_started.elapsed().as_millis();
    db::set_last_played(&state.pool, instance_id).await?;
    if let Some(addr) = quick_play_multiplayer
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        let _ = db::record_server_join(&state.pool, instance_id, addr).await;
    }
    eprintln!(
		"[AML launch perf] instance={instance_id} total={}ms java={}ms manifest={}ms args={}ms spawn={}ms",
		launch_started.elapsed().as_millis(),
		java_check_ms,
		manifest_ms,
		args_ms,
		spawn_ms,
	);
    Ok(meta)
}

/// Required Java major version from cached Minecraft version metadata.
pub async fn required_java_major_for_instance(instance_id: &str) -> Result<u32> {
    let state = try_state()?;
    let resource = resource_dir().await?;
    let mut instance = db::get_instance(&state.pool, instance_id).await?;
    ensure_valid_game_version(&state.pool, &resource, &mut instance).await?;
    let loader = ModLoader::parse(&instance.loader);
    let version_jar_id = if matches!(loader, ModLoader::Vanilla) {
        instance.game_version.clone()
    } else {
        format!(
            "{}-{}",
            instance.game_version,
            instance.loader_version.as_deref().unwrap_or("unknown")
        )
    };
    let info = match manifest::load_cached_version_info(&resource, &version_jar_id).await {
        Ok(info) => info,
        Err(_) => match manifest::load_cached_version_info(&resource, &instance.path).await {
            Ok(info) => info,
            Err(_) => {
                let (info, _) = manifest::resolve_version_info(
                    &resource,
                    &instance.game_version,
                    &loader,
                    instance.loader_version.as_deref(),
                )
                .await?;
                info
            }
        },
    };
    Ok(super::args::required_java_major(&info))
}
