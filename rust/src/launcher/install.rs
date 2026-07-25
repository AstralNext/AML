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
    let java_arch = match java_arch {
        "x86_64" => "x86_64",
        "aarch64" => "aarch64",
        other => other,
    };

    report(0.08, "Downloading Minecraft files…".into());
    if force {
        // Force re-download by removing client jar marker is enough; download checks sha1
    }
    download::download_minecraft(
        &resource,
        &info,
        &version_jar_id,
        java_arch,
        on_progress.clone(),
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

    let mut data_map: HashMap<String, String> = HashMap::new();
    if let Some(data) = &info.data {
        for (k, v) in data {
            data_map.insert(k.clone(), v.client.clone());
        }
    }
    data_map.insert("SIDE".into(), "client".into());
    data_map.insert(
        "MINECRAFT_JAR".into(),
        client_jar.to_string_lossy().to_string(),
    );
    data_map.insert("ROOT".into(), instance_dir.to_string_lossy().to_string());
    data_map.insert(
        "LIBRARY_DIR".into(),
        libraries.to_string_lossy().to_string(),
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
            .map(|a| substitute_processor_arg(a, &data_map, resource_dir))
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

fn substitute_processor_arg(
    arg: &str,
    data: &HashMap<String, String>,
    resource_dir: &str,
) -> Result<String> {
    let mut out = arg.to_string();
    // {KEY} replacements
    for (k, v) in data {
        let token = format!("{{{k}}}");
        if out.contains(&token) {
            let replaced = if v.starts_with('[') && v.ends_with(']') {
                let artifact = &v[1..v.len() - 1];
                dirs::libraries(resource_dir)
                    .join(get_path_from_artifact(artifact)?)
                    .to_string_lossy()
                    .to_string()
            } else if v.starts_with('/') {
                dirs::instance_dir(resource_dir, "")
                    .parent()
                    .unwrap_or(std::path::Path::new(resource_dir))
                    .join(v.trim_start_matches('/'))
                    .to_string_lossy()
                    .to_string()
            } else {
                v.clone()
            };
            out = out.replace(&token, &replaced);
        }
    }
    // [maven:coord]
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

pub async fn launch_instance(
    instance_id: &str,
    java_path: String,
    quick_play_singleplayer: Option<String>,
    quick_play_multiplayer: Option<String>,
) -> Result<super::process::ProcessMetadata> {
    let launch_started = Instant::now();
    let state = try_state()?;
    let resource = resource_dir().await?;
    let instance = db::get_instance(&state.pool, instance_id).await?;
    if instance.install_stage != InstallStage::Installed.as_str() {
        anyhow::bail!("instance is not installed");
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
                .ok_or_else(|| anyhow!("missing loader version"))?
        )
    };

    let info = manifest::load_cached_version_info(&resource, &version_jar_id).await?;
    let required_major = super::args::required_java_major(&info);
    let java_arch = match std::env::consts::ARCH {
        "x86_64" => "x86_64",
        "aarch64" => "aarch64",
        other => other,
    };

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
    let extra_source = instance
        .extra_jvm_args
        .as_deref()
        .or(defaults.extra_jvm_args.as_deref())
        .unwrap_or("");
    let extra: Vec<String> = extra_source
        .split_whitespace()
        .map(|s| s.to_string())
        .collect();

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
        quick_play_singleplayer.as_deref(),
        quick_play_multiplayer.as_deref(),
        server_endpoint,
        quick_play_version,
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
    let environment = instance
        .environment_vars
        .as_deref()
        .or(defaults.environment_vars.as_deref())
        .filter(|value| !value.trim().is_empty());
    if let Some(environment) = environment {
        let values: HashMap<String, String> =
            serde_json::from_str(environment).context("环境变量配置不是有效的 JSON 对象")?;
        args.env = values.into_iter().collect();
    }
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
    let instance = db::get_instance(&state.pool, instance_id).await?;
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
    };
    Ok(super::args::required_java_major(&info))
}
