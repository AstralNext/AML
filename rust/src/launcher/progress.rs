//! Nested install progress encoded into the existing `(f64, String)` callback
//! so Flutter does not need a new FRB signature.
//!
//! Message format: `__TASK__` + JSON [TaskProgress].
//! Control markers (`__INSTANCE_CREATED__`, `__SKIPPED_FILES__`) pass through.

use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub type ProgressFn = Arc<dyn Fn(f64, String) + Send + Sync>;

pub const TASK_PREFIX: &str = "__TASK__";

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskProgress {
    #[serde(default)]
    pub stage: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub downloaded: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speed: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sub: Option<f64>,
}

pub fn encode_task(task: &TaskProgress) -> String {
    match serde_json::to_string(task) {
        Ok(json) => format!("{TASK_PREFIX}{json}"),
        Err(_) => task.stage.clone(),
    }
}

pub fn decode_task(msg: &str) -> Option<TaskProgress> {
    let json = msg.strip_prefix(TASK_PREFIX)?;
    serde_json::from_str(json).ok()
}

pub fn is_control_marker(msg: &str) -> bool {
    msg.starts_with("__INSTANCE_CREATED__:") || msg.starts_with("__SKIPPED_FILES__:")
}

/// Map a child 0..=1 progress into `[start, end]` on the parent bar.
/// Child `__TASK__` payloads keep their sub-task fields.
pub fn nest_progress(
    parent: Option<ProgressFn>,
    start: f64,
    end: f64,
    stage: impl Into<String>,
) -> Option<ProgressFn> {
    let parent = parent?;
    let stage = Arc::new(stage.into());
    Some(Arc::new(move |p, msg| {
        let overall = start + p.clamp(0.0, 1.0) * (end - start);
        if is_control_marker(&msg) {
            parent(overall, msg);
            return;
        }
        let task = if let Some(inner) = decode_task(&msg) {
            let mut inner = inner;
            if inner.stage.trim().is_empty() {
                inner.stage = (*stage).clone();
            }
            inner
        } else {
            TaskProgress {
                stage: msg,
                sub: Some(p.clamp(0.0, 1.0)),
                ..TaskProgress::default()
            }
        };
        parent(overall, encode_task(&task));
    }))
}

pub fn report_task(cb: &Option<ProgressFn>, overall: f64, task: TaskProgress) {
    if let Some(cb) = cb {
        cb(overall, encode_task(&task));
    }
}

/// Byte callback used while streaming a response body.
pub type BytesProgressFn = Arc<dyn Fn(u64, Option<u64>) + Send + Sync>;

/// Concurrent file batch: overall bar follows completed/total, sub-task shows
/// live bytes + aggregate speed.
#[derive(Clone)]
pub struct BatchReporter {
    inner: Arc<BatchInner>,
}

struct BatchInner {
    cb: ProgressFn,
    stage: String,
    start: f64,
    end: f64,
    total: u64,
    completed: AtomicU64,
    bytes: AtomicU64,
    active: AtomicU32,
    started: Instant,
    last_emit: Mutex<Instant>,
    current_name: Mutex<String>,
}

impl BatchReporter {
    pub fn new(
        cb: ProgressFn,
        stage: impl Into<String>,
        start: f64,
        end: f64,
        total: u64,
    ) -> Self {
        Self {
            inner: Arc::new(BatchInner {
                cb,
                stage: stage.into(),
                start,
                end,
                total: total.max(1),
                completed: AtomicU64::new(0),
                bytes: AtomicU64::new(0),
                active: AtomicU32::new(0),
                started: Instant::now(),
                last_emit: Mutex::new(Instant::now() - Duration::from_secs(1)),
                current_name: Mutex::new(String::new()),
            }),
        }
    }

    pub fn skip_file(&self) {
        let n = self.inner.completed.fetch_add(1, Ordering::Relaxed) + 1;
        self.emit(n == self.inner.total || n % 20 == 0);
    }

    pub fn begin_file(&self, name: &str) {
        self.inner.active.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut g) = self.inner.current_name.lock() {
            *g = name.to_string();
        }
        self.emit(false);
    }

    pub fn add_bytes(&self, n: u64) {
        if n == 0 {
            return;
        }
        self.inner.bytes.fetch_add(n, Ordering::Relaxed);
        self.emit(false);
    }

    pub fn finish_file(&self) {
        let n = self.inner.completed.fetch_add(1, Ordering::Relaxed) + 1;
        self.inner.active.fetch_sub(1, Ordering::Relaxed);
        self.emit(n == self.inner.total);
    }

    /// Per-file byte callback (absolute downloaded count).
    pub fn file_bytes_cb(&self, name: &str) -> BytesProgressFn {
        self.begin_file(name);
        let last = AtomicU64::new(0);
        let this = self.clone();
        Arc::new(move |got, _total| {
            let prev = last.swap(got, Ordering::Relaxed);
            if got > prev {
                this.add_bytes(got - prev);
            }
        })
    }

    fn emit(&self, force: bool) {
        {
            let mut last = match self.inner.last_emit.lock() {
                Ok(g) => g,
                Err(_) => return,
            };
            if !force && last.elapsed() < Duration::from_millis(120) {
                return;
            }
            *last = Instant::now();
        }
        let completed = self.inner.completed.load(Ordering::Relaxed);
        let total = self.inner.total;
        let frac = (completed as f64 / total as f64).clamp(0.0, 1.0);
        let overall = self.inner.start + frac * (self.inner.end - self.inner.start);
        let elapsed = self.inner.started.elapsed().as_secs_f64().max(0.05);
        let bytes = self.inner.bytes.load(Ordering::Relaxed);
        let speed = (bytes as f64 / elapsed) as u64;
        let name = self
            .inner
            .current_name
            .lock()
            .ok()
            .map(|g| g.clone())
            .filter(|s| !s.is_empty());
        let active = self.inner.active.load(Ordering::Relaxed);
        (self.inner.cb)(
            overall,
            encode_task(&TaskProgress {
                stage: self.inner.stage.clone(),
                current: Some(completed),
                total: Some(total),
                name,
                downloaded: Some(bytes),
                size: None,
                speed: Some(speed),
                active: Some(active),
                sub: Some(frac),
            }),
        );
    }
}

/// Single-file transfer mapped into `[start, end]` of the parent bar.
pub fn file_bytes_cb(
    cb: ProgressFn,
    stage: impl Into<String>,
    name: impl Into<String>,
    start: f64,
    end: f64,
) -> BytesProgressFn {
    let stage = stage.into();
    let name = name.into();
    let started = Instant::now();
    let last_emit = Mutex::new(Instant::now() - Duration::from_secs(1));
    Arc::new(move |got, total| {
        {
            let mut last = match last_emit.lock() {
                Ok(g) => g,
                Err(_) => return,
            };
            let done = total.map(|t| got >= t).unwrap_or(false);
            if !done && last.elapsed() < Duration::from_millis(100) {
                return;
            }
            *last = Instant::now();
        }
        let sub = total
            .filter(|t| *t > 0)
            .map(|t| (got as f64 / t as f64).clamp(0.0, 1.0))
            .unwrap_or(0.0);
        let overall = start + sub * (end - start);
        let speed = (got as f64 / started.elapsed().as_secs_f64().max(0.05)) as u64;
        cb(
            overall,
            encode_task(&TaskProgress {
                stage: stage.clone(),
                name: Some(name.clone()),
                downloaded: Some(got),
                size: total,
                speed: Some(speed),
                sub: Some(sub),
                ..TaskProgress::default()
            }),
        );
    })
}
