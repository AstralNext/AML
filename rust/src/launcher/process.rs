use anyhow::{anyhow, Result};
use dashmap::DashMap;
use once_cell::sync::Lazy;
use quick_xml::events::Event;
use quick_xml::{Reader, XmlVersion};
use std::collections::VecDeque;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::Mutex;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::Mutex as AsyncMutex;
use uuid::Uuid;

use super::args::LaunchArgs;
use super::rpc::RpcServer;

const LIVE_LOG_CAP: usize = 50_000;
const LOG_BATCH_SIZE: usize = 64;
const LOG_BATCH_INTERVAL: std::time::Duration = std::time::Duration::from_millis(50);

pub static PROCESS_MANAGER: Lazy<ProcessManager> = Lazy::new(ProcessManager::default);

/// Listeners for process lifecycle (`launched` / `finished`).
static PROCESS_LISTENERS: Lazy<Mutex<Vec<ProcessListener>>> = Lazy::new(|| Mutex::new(Vec::new()));

/// Listeners for live log lines pushed from stdout/stderr.
static LOG_LISTENERS: Lazy<Mutex<Vec<LogListener>>> = Lazy::new(|| Mutex::new(Vec::new()));

pub async fn run_hook(
    command: &str,
    cwd: &std::path::Path,
    env: &[(String, String)],
) -> Result<()> {
    if command.trim().is_empty() {
        return Ok(());
    }
    let mut cmd = shell_command(command);
    cmd.current_dir(cwd).envs(env.iter().cloned());
    let output = cmd.output().await?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(anyhow!(
            "启动命令执行失败（{}）{}",
            output.status,
            if stderr.is_empty() {
                String::new()
            } else {
                format!(": {stderr}")
            }
        ));
    }
    Ok(())
}

fn shell_command(command: &str) -> Command {
    #[cfg(windows)]
    {
        let mut cmd = Command::new("cmd.exe");
        cmd.args(["/D", "/S", "/C", command]);
        super::win_process::hide_console_window(&mut cmd);
        cmd
    }
    #[cfg(not(windows))]
    {
        let mut cmd = Command::new("/bin/sh");
        cmd.args(["-lc", command]);
        cmd
    }
}

type ProcessListener = Arc<dyn Fn(ProcessEvent) + Send + Sync>;
type LogListener = Arc<dyn Fn(LiveLogEvent) + Send + Sync>;

#[derive(Clone, Debug)]
pub struct ProcessEvent {
    pub instance_id: String,
    pub uuid: String,
    /// `"launched"` | `"finished"`
    pub event: String,
    pub message: String,
}

#[derive(Clone, Debug)]
pub struct LiveLogEvent {
    pub instance_id: String,
    /// One line or a newline-delimited batch.
    pub line: String,
    /// When true, [line] is empty and the live buffer was cleared.
    pub cleared: bool,
}

#[derive(Default)]
pub struct ProcessManager {
    processes: DashMap<String, RunningProcess>,
    /// instance_id → recent log lines
    live_logs: DashMap<String, Mutex<VecDeque<String>>>,
}

pub struct RunningProcess {
    pub uuid: String,
    pub instance_id: String,
    /// Quick Play world folder, if this launch entered a specific save.
    pub quick_play_world: Option<String>,
    /// Wrapped for Sync access to the child process.
    pub child: Arc<AsyncMutex<Child>>,
    /// Kept alive for the process lifetime so the launch RPC stays connected.
    _rpc_server: RpcServer,
}

#[derive(Clone, Debug)]
pub struct ProcessMetadata {
    pub uuid: String,
    pub instance_id: String,
}

pub fn subscribe_process_events(listener: ProcessListener) {
    PROCESS_LISTENERS.lock().unwrap().push(listener);
}

pub fn subscribe_live_log_events(listener: LogListener) {
    LOG_LISTENERS.lock().unwrap().push(listener);
}

pub fn emit_process(event: ProcessEvent) {
    let listeners = PROCESS_LISTENERS.lock().unwrap().clone();
    for listener in listeners {
        listener(event.clone());
    }
}

pub fn emit_live_log(event: LiveLogEvent) {
    let listeners = LOG_LISTENERS.lock().unwrap().clone();
    for listener in listeners {
        listener(event.clone());
    }
}

impl ProcessManager {
    pub fn get_by_instance(&self, instance_id: &str) -> Option<ProcessMetadata> {
        self.processes.iter().find_map(|e| {
            if e.instance_id == instance_id {
                Some(ProcessMetadata {
                    uuid: e.uuid.clone(),
                    instance_id: e.instance_id.clone(),
                })
            } else {
                None
            }
        })
    }

    pub fn list(&self) -> Vec<ProcessMetadata> {
        self.processes
            .iter()
            .map(|e| ProcessMetadata {
                uuid: e.uuid.clone(),
                instance_id: e.instance_id.clone(),
            })
            .collect()
    }

    pub fn clear_live_logs(&self, instance_id: &str) {
        self.live_logs
            .entry(instance_id.to_string())
            .or_insert_with(|| Mutex::new(VecDeque::new()))
            .lock()
            .unwrap()
            .clear();
        emit_live_log(LiveLogEvent {
            instance_id: instance_id.to_string(),
            line: String::new(),
            cleared: true,
        });
    }

    pub fn push_live_log(&self, instance_id: &str, line: String) {
        self.push_live_logs(instance_id, vec![line]);
    }

    pub fn push_live_logs(&self, instance_id: &str, lines: Vec<String>) {
        if lines.is_empty() {
            return;
        }
        let entry = self
            .live_logs
            .entry(instance_id.to_string())
            .or_insert_with(|| Mutex::new(VecDeque::new()));
        let mut buf = entry.lock().unwrap();
        for line in &lines {
            buf.push_back(line.clone());
        }
        while buf.len() > LIVE_LOG_CAP {
            buf.pop_front();
        }
        drop(buf);
        emit_live_log(LiveLogEvent {
            instance_id: instance_id.to_string(),
            line: lines.join("\n"),
            cleared: false,
        });
    }

    pub fn get_live_logs(&self, instance_id: &str) -> Vec<String> {
        self.live_logs
            .get(instance_id)
            .map(|e| e.lock().unwrap().iter().cloned().collect())
            .unwrap_or_default()
    }

    pub async fn kill_instance(&self, instance_id: &str) -> Result<()> {
        // Call `Child::kill` briefly while the exit watcher uses `try_wait` polling.
        // Safe because the exit watcher uses `try_wait` polling (not a long `wait()` lock).
        let children: Vec<Arc<AsyncMutex<Child>>> = self
            .processes
            .iter()
            .filter(|e| e.instance_id == instance_id)
            .map(|e| e.child.clone())
            .collect();
        for child in children {
            let mut guard = child.lock().await;
            guard.kill().await?;
        }
        Ok(())
    }

    pub async fn spawn(
        &self,
        instance_id: &str,
        args: LaunchArgs,
        log_path: std::path::PathBuf,
        rpc_server: RpcServer,
        instance_name: &str,
        xml_logging: bool,
        quick_play_world: Option<String>,
    ) -> Result<ProcessMetadata> {
        if self.get_by_instance(instance_id).is_some() {
            return Err(anyhow!("instance already running"));
        }

        if let Some(parent) = log_path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        self.clear_live_logs(instance_id);

        let launch_header = format!(
			"[AML] Launching\n  java: {}\n  cwd: {}\n  entry: {}\n  main: {}\n  jvm: {}\n  game: {}\n",
			args.java.display(),
			args.cwd.display(),
			args.entry_class,
			args.minecraft_main_class,
			args.jvm_args.join(" "),
			args.game_args.join(" "),
		);
        append_log(&log_path, &launch_header).await?;
        self.push_live_logs(
            instance_id,
            launch_header.lines().map(str::to_string).collect(),
        );

        if !args.java.is_file() {
            return Err(anyhow!("Java 不存在: {}", args.java.display()));
        }
        if !args.cwd.is_dir() {
            return Err(anyhow!("实例目录不存在: {}", args.cwd.display()));
        }

        let mut launch_arguments = args.jvm_args.clone();
        launch_arguments.push(args.entry_class.clone());
        launch_arguments.push(args.minecraft_main_class.clone());
        launch_arguments.extend(args.game_args.clone());
        let mut cmd = if let Some(wrapper) = args
            .wrapper_command
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        {
            let wrapper_parts = shell_words::split(wrapper)
                .map_err(|error| anyhow!("包装器命令解析失败: {error}"))?;
            let (executable, wrapper_args) = wrapper_parts
                .split_first()
                .ok_or_else(|| anyhow!("包装器命令不能为空"))?;
            let mut command = Command::new(executable);
            command
                .args(wrapper_args)
                .arg(&args.java)
                .args(&launch_arguments);
            command
        } else {
            let mut command = Command::new(&args.java);
            command.args(&launch_arguments);
            command
        };
        cmd.current_dir(&args.cwd)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(false);
        super::win_process::hide_console_window(&mut cmd);
        cmd.env_remove("_JAVA_OPTIONS");
        for (k, v) in &args.env {
            cmd.env(k, v);
        }

        let mut child = cmd.spawn().map_err(|e| {
            anyhow!(
                "启动进程失败: {e}（java={}, cwd={}）",
                args.java.display(),
                args.cwd.display()
            )
        })?;

        // Await RPC handshake before treating launch as complete.
        for (key, value) in [("modrinth.profile.name", instance_name)] {
            rpc_server
                .call_method_2::<()>("set_system_property", key, value)
                .await
                .map_err(|e| anyhow!("launcher RPC set_system_property failed: {e}"))?;
        }
        rpc_server
            .call_method::<()>("launch")
            .await
            .map_err(|e| anyhow!("launcher RPC launch failed: {e}"))?;

        let uuid = Uuid::new_v4().to_string();
        let instance_id_owned = instance_id.to_string();

        if let Some(stdout) = child.stdout.take() {
            let log_path = log_path.clone();
            let instance_id = instance_id_owned.clone();
            tokio::spawn(async move {
                consume_output(stdout, instance_id, log_path, xml_logging).await;
            });
        }
        if let Some(stderr) = child.stderr.take() {
            let log_path = log_path.clone();
            let instance_id = instance_id_owned.clone();
            tokio::spawn(async move {
                consume_output(stderr, instance_id, log_path, xml_logging).await;
            });
        }

        let meta = ProcessMetadata {
            uuid: uuid.clone(),
            instance_id: instance_id_owned.clone(),
        };

        let child = Arc::new(AsyncMutex::new(child));
        self.processes.insert(
            uuid.clone(),
            RunningProcess {
                uuid: uuid.clone(),
                instance_id: instance_id_owned.clone(),
                quick_play_world: quick_play_world.clone(),
                child: child.clone(),
                _rpc_server: rpc_server,
            },
        );

        emit_process(ProcessEvent {
            instance_id: instance_id_owned.clone(),
            uuid: uuid.clone(),
            event: "launched".into(),
            message: "Launched Minecraft".into(),
        });

        let uuid_watch = uuid.clone();
        let instance_for_exit = instance_id_owned.clone();
        let post_exit_command = args.post_exit_command.clone();
        let post_exit_cwd = args.cwd.clone();
        let post_exit_env = args.env.clone();
        let quick_play_for_exit = quick_play_world;
        // Poll `try_wait` so kill can take the lock (avoid holding `wait()`).
        tokio::spawn(async move {
            let status = loop {
                let polled = {
                    let mut guard = child.lock().await;
                    match guard.try_wait() {
                        Ok(Some(status)) => Some(Ok(status)),
                        Ok(None) => None,
                        Err(e) => Some(Err(e)),
                    }
                };
                match polled {
                    Some(result) => break result,
                    None => {
                        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    }
                }
            };
            let exited_successfully = status.as_ref().is_ok_and(|value| value.success());
            let status_msg = match status {
                Ok(s) => format!("[AML] Process exited: {s}"),
                Err(e) => format!("[AML] Process wait failed: {e}"),
            };
            PROCESS_MANAGER.push_live_log(&instance_for_exit, status_msg);
            if exited_successfully {
                if let Some(command) = post_exit_command {
                    if let Err(error) = run_hook(&command, &post_exit_cwd, &post_exit_env).await {
                        PROCESS_MANAGER.push_live_log(
                            &instance_for_exit,
                            format!("[AML] 退出后命令失败: {error:#}"),
                        );
                    }
                }
            }
            // Auto world backup after exit (session.lock released by Minecraft).
            // Delay briefly so the OS releases file locks.
            let backup_instance = instance_for_exit.clone();
            let backup_world = quick_play_for_exit;
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                if let Err(e) =
                    crate::launcher::world_backup::auto_backup_after_exit(&backup_instance, backup_world)
                        .await
                {
                    eprintln!("[AML] auto-backup after exit failed: {e:#}");
                }
            });
            PROCESS_MANAGER.processes.remove(&uuid_watch);
            emit_process(ProcessEvent {
                instance_id: instance_for_exit,
                uuid: uuid_watch,
                event: "finished".into(),
                message: "Exited process".into(),
            });
        });

        Ok(meta)
    }
}

#[derive(Default)]
struct Log4jEvent {
    timestamp_millis: Option<i64>,
    logger: Option<String>,
    level: Option<String>,
    thread: Option<String>,
    message: Option<String>,
    throwable: Option<String>,
}

impl Log4jEvent {
    fn formatted_line(&self) -> Option<String> {
        let message = self.message.as_deref()?.trim();
        let timestamp = self
            .timestamp_millis
            .and_then(chrono::DateTime::from_timestamp_millis)
            .map(|time| {
                time.with_timezone(&chrono::Local)
                    .format("%H:%M:%S")
                    .to_string()
            })
            .unwrap_or_else(|| "??:??:??".to_string());
        let thread = self.thread.as_deref().unwrap_or("");
        let level = self.level.as_deref().unwrap_or("");
        let logger = self.logger.as_deref().unwrap_or("");
        let source = if logger.is_empty() {
            level.to_string()
        } else {
            format!("{logger}/{level}")
        };
        Some(format!("[{timestamp}] [{thread}] [{source}]: {message}"))
    }
}

async fn consume_xml_output<R>(reader: R, instance_id: String, log_path: std::path::PathBuf)
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut reader = Reader::from_reader(BufReader::new(reader));
    reader.config_mut().enable_all_checks(false);
    let mut buffer = Vec::new();
    let mut pending = Vec::with_capacity(LOG_BATCH_SIZE);
    let mut current = Log4jEvent::default();
    let mut content = String::new();
    let mut in_event = false;
    let mut in_message = false;
    let mut in_throwable = false;
    let mut interval = tokio::time::interval(LOG_BATCH_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    interval.tick().await;

    loop {
        tokio::select! {
            result = reader.read_event_into_async(&mut buffer) => {
                match result {
                    Ok(Event::Eof) => {
                        flush_log_batch(&instance_id, &log_path, &mut pending).await;
                        break;
                    }
                    Err(error) => {
                        pending.push(format!("[AML] Log4j XML parse failed: {error}"));
                        flush_log_batch(&instance_id, &log_path, &mut pending).await;
                        break;
                    }
                    Ok(Event::Start(element)) => {
                        match element.local_name().as_ref() {
                            b"Event" => {
                                current = Log4jEvent::default();
                                in_event = true;
                                for attribute in element.attributes().flatten() {
                                    let value = String::from_utf8_lossy(attribute.value.as_ref()).into_owned();
                                    match attribute.key.local_name().as_ref() {
                                        b"logger" => current.logger = Some(value),
                                        b"level" => current.level = Some(value),
                                        b"thread" => current.thread = Some(value),
                                        b"timestamp" => current.timestamp_millis = value.parse().ok(),
                                        _ => {}
                                    }
                                }
                            }
                            b"Message" => {
                                in_message = true;
                                content.clear();
                            }
                            b"Throwable" => {
                                in_throwable = true;
                                content.clear();
                            }
                            _ => {}
                        }
                    }
                    Ok(Event::End(element)) => {
                        match element.local_name().as_ref() {
                            b"Message" => {
                                in_message = false;
                                current.message = Some(content.clone());
                            }
                            b"Throwable" => {
                                in_throwable = false;
                                if !content.is_empty() {
                                    current.throwable = Some(content.clone());
                                }
                            }
                            b"Event" => {
                                in_event = false;
                                if let Some(line) = current.formatted_line() {
                                    pending.push(line);
                                }
                                if let Some(throwable) = current.throwable.take() {
                                    pending.extend(
                                        throwable
                                            .lines()
                                            .filter(|line| !line.is_empty())
                                            .map(str::to_string),
                                    );
                                }
                                if pending.len() >= LOG_BATCH_SIZE {
                                    flush_log_batch(&instance_id, &log_path, &mut pending).await;
                                }
                            }
                            _ => {}
                        }
                    }
                    Ok(Event::Text(text)) => {
                        if in_message || in_throwable {
                            if let Ok(decoded) = text.xml_content(XmlVersion::Implicit1_0) {
                                content.push_str(&decoded);
                            }
                        } else if !in_event {
                            if let Ok(decoded) = text.xml_content(XmlVersion::Implicit1_0) {
                                let decoded = decoded.trim();
                                if !decoded.is_empty() {
                                    pending.extend(decoded.lines().map(str::to_string));
                                }
                            }
                        }
                    }
                    Ok(Event::CData(text)) => {
                        if in_message || in_throwable {
                            if let Ok(decoded) = text.xml_content(XmlVersion::Implicit1_0) {
                                content.push_str(&decoded);
                            }
                        }
                    }
                    Ok(_) => {}
                }
                buffer.clear();
            }
            _ = interval.tick() => {
                flush_log_batch(&instance_id, &log_path, &mut pending).await;
            }
        }
    }
}

async fn consume_output<R>(
    reader: R,
    instance_id: String,
    log_path: std::path::PathBuf,
    xml_logging: bool,
) where
    R: tokio::io::AsyncRead + Unpin,
{
    if xml_logging {
        consume_xml_output(reader, instance_id, log_path).await;
        return;
    }
    let mut lines = BufReader::new(reader).lines();
    let mut pending = Vec::with_capacity(LOG_BATCH_SIZE);
    let mut interval = tokio::time::interval(LOG_BATCH_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    interval.tick().await;

    loop {
        tokio::select! {
            result = lines.next_line() => {
                match result {
                    Ok(Some(line)) => {
                        pending.push(line);
                        if pending.len() >= LOG_BATCH_SIZE {
                            flush_log_batch(&instance_id, &log_path, &mut pending).await;
                        }
                    }
                    Ok(None) | Err(_) => {
                        flush_log_batch(&instance_id, &log_path, &mut pending).await;
                        break;
                    }
                }
            }
            _ = interval.tick() => {
                flush_log_batch(&instance_id, &log_path, &mut pending).await;
            }
        }
    }
}

async fn flush_log_batch(instance_id: &str, log_path: &std::path::Path, pending: &mut Vec<String>) {
    if pending.is_empty() {
        return;
    }
    let batch = std::mem::take(pending);
    let joined = batch.join("\n");
    PROCESS_MANAGER.push_live_logs(instance_id, batch);
    let _ = append_log(log_path, &joined).await;
}

async fn append_log(path: &std::path::Path, line: &str) -> Result<()> {
    use tokio::io::AsyncWriteExt;
    let mut file = tokio::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .await?;
    file.write_all(format!("{line}\n").as_bytes()).await?;
    Ok(())
}
