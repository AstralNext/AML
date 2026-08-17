//! HTTP file downloader.
//!
//! Files **larger than 10 MiB** are split into parallel `Range` requests when
//! the server answers `206 Partial Content`. Smaller files, or servers that
//! ignore `Range`, stay on a single streamed GET. Each part retries on its
//! own; a range-unaware server falls back to one connection instead of failing.

use anyhow::{anyhow, Context, Result};
use futures::StreamExt;
use reqwest::header::{HeaderValue, ACCEPT_ENCODING, RANGE};
use reqwest::{Client, Response, StatusCode};
use sha1::{Digest, Sha1};
use std::io::SeekFrom;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncSeekExt, AsyncWriteExt};
use tokio::task::JoinSet;

use super::progress::BytesProgressFn;

/// Parallel download kicks in strictly above this size.
pub const MULTI_THREAD_THRESHOLD: u64 = 10 * 1024 * 1024;

/// Cap connections per file so a pack of large mods cannot open hundreds of sockets.
pub const MAX_PARTS: usize = 8;

/// Keep parts coarse enough that TCP/TLS setup does not dominate.
pub const MIN_PART_SIZE: u64 = 2 * 1024 * 1024;

const PART_ATTEMPTS: u32 = 3;
const HEADER_TIMEOUT: Duration = Duration::from_secs(60);
const IDLE_TIMEOUT: Duration = Duration::from_secs(90);

#[derive(Debug)]
struct RangeNotSupported;

impl std::fmt::Display for RangeNotSupported {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "server ignored byte ranges")
    }
}

impl std::error::Error for RangeNotSupported {}

struct ByteMeter {
    got: AtomicU64,
    total: Option<u64>,
    cb: Option<BytesProgressFn>,
    last: Mutex<Instant>,
}

impl ByteMeter {
    fn new(total: Option<u64>, cb: Option<BytesProgressFn>) -> Arc<Self> {
        Arc::new(Self {
            got: AtomicU64::new(0),
            total,
            cb,
            last: Mutex::new(Instant::now() - Duration::from_secs(1)),
        })
    }

    fn snapshot(&self) -> u64 {
        self.got.load(Ordering::Relaxed)
    }

    fn restore(&self, value: u64) {
        self.got.store(value, Ordering::Relaxed);
    }

    fn add(&self, n: u64) {
        if n == 0 {
            return;
        }
        let got = self.got.fetch_add(n, Ordering::Relaxed) + n;
        let force = self.total.is_some_and(|t| got >= t);
        let should_emit = force
            || self
                .last
                .lock()
                .map(|g| g.elapsed() >= Duration::from_millis(100))
                .unwrap_or(true);
        if !should_emit {
            return;
        }
        if let Ok(mut g) = self.last.lock() {
            *g = Instant::now();
        }
        if let Some(cb) = &self.cb {
            cb(got, self.total);
        }
    }

    fn finish(&self) {
        if let Some(cb) = &self.cb {
            let got = self.got.load(Ordering::Relaxed);
            cb(got, self.total.or(Some(got)));
        }
    }
}

/// GET [url] into memory, using parallel ranges when the object is large.
pub async fn get_bytes(
    client: &Client,
    url: &str,
    extra_headers: Option<&[(&str, &str)]>,
    on_bytes: Option<BytesProgressFn>,
) -> Result<Vec<u8>> {
    match probe(client, url, extra_headers).await? {
        Probe::Single(resp, total) => {
            let meter = ByteMeter::new(total, on_bytes);
            let bytes = read_body_vec(resp, &meter).await?;
            meter.finish();
            Ok(bytes)
        }
        Probe::Ranged(total) => {
            match get_bytes_ranged(client, url, extra_headers, total, on_bytes.clone()).await {
                Ok(bytes) => Ok(bytes),
                Err(err) if err.downcast_ref::<RangeNotSupported>().is_some() => {
                    tracing::debug!(
                        "range download unsupported for {url}, falling back to single GET"
                    );
                    get_bytes_single(client, url, extra_headers, on_bytes).await
                }
                Err(err) => {
                    tracing::debug!("range download failed for {url}: {err:#}; falling back");
                    get_bytes_single(client, url, extra_headers, on_bytes).await
                }
            }
        }
    }
}

/// GET [url] onto [dest] (via a `.amlpart` sibling). Parallel ranges stream
/// each part to disk so a 100 MiB jar does not sit in RAM twice.
pub async fn get_to_path(
    client: &Client,
    url: &str,
    dest: &Path,
    extra_headers: Option<&[(&str, &str)]>,
    expected_sha1: Option<&str>,
    on_bytes: Option<BytesProgressFn>,
) -> Result<()> {
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let tmp = part_path(dest);
    let _ = tokio::fs::remove_file(&tmp).await;
    let result = get_to_path_inner(client, url, &tmp, extra_headers, on_bytes).await;
    match result {
        Ok(()) => {
            if let Some(expected) = expected_sha1.map(str::trim).filter(|s| !s.is_empty()) {
                let actual = sha1_file(&tmp).await?;
                if !actual.eq_ignore_ascii_case(expected) {
                    let _ = tokio::fs::remove_file(&tmp).await;
                    anyhow::bail!(
                        "sha1 mismatch for {}: expected {expected}, got {actual}",
                        dest.display()
                    );
                }
            }
            if dest.exists() {
                tokio::fs::remove_file(dest).await.ok();
            }
            tokio::fs::rename(&tmp, dest)
                .await
                .with_context(|| format!("rename {} -> {}", tmp.display(), dest.display()))?;
            Ok(())
        }
        Err(err) => {
            let _ = tokio::fs::remove_file(&tmp).await;
            Err(err)
        }
    }
}

async fn get_to_path_inner(
    client: &Client,
    url: &str,
    tmp: &Path,
    extra_headers: Option<&[(&str, &str)]>,
    on_bytes: Option<BytesProgressFn>,
) -> Result<()> {
    match probe(client, url, extra_headers).await? {
        Probe::Single(resp, total) => {
            let meter = ByteMeter::new(total, on_bytes);
            stream_to_new_file(resp, tmp, &meter).await?;
            meter.finish();
            Ok(())
        }
        Probe::Ranged(total) => {
            match get_path_ranged(client, url, extra_headers, tmp, total, on_bytes.clone()).await {
                Ok(()) => Ok(()),
                Err(err) if err.downcast_ref::<RangeNotSupported>().is_some() => {
                    tracing::debug!("range download unsupported for {url}, falling back");
                    get_path_single(client, url, extra_headers, tmp, on_bytes).await
                }
                Err(err) => {
                    tracing::debug!("range download failed for {url}: {err:#}; falling back");
                    let _ = tokio::fs::remove_file(tmp).await;
                    get_path_single(client, url, extra_headers, tmp, on_bytes).await
                }
            }
        }
    }
}

enum Probe {
    Single(Response, Option<u64>),
    Ranged(u64),
}

fn owned_headers(extra: Option<&[(&str, &str)]>) -> Vec<(String, String)> {
    extra
        .unwrap_or(&[])
        .iter()
        .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
        .collect()
}

async fn probe(
    client: &Client,
    url: &str,
    extra_headers: Option<&[(&str, &str)]>,
) -> Result<Probe> {
    let headers = owned_headers(extra_headers);
    let resp = send(client, url, &headers, Some("bytes=0-0")).await?;
    let status = resp.status();
    if status == StatusCode::PARTIAL_CONTENT {
        let total = parse_content_range_total(resp.headers().get(reqwest::header::CONTENT_RANGE));
        // Drain the 1-byte body so the connection can be reused.
        let _ = resp.bytes().await;
        match total {
            Some(size) if size > MULTI_THREAD_THRESHOLD => Ok(Probe::Ranged(size)),
            _ => {
                let full = send(client, url, &headers, None).await?;
                let len = full.content_length();
                Ok(Probe::Single(full, len))
            }
        }
    } else if status.is_success() {
        let len = resp.content_length();
        Ok(Probe::Single(resp, len))
    } else {
        Err(anyhow!("HTTP {status}: {url}"))
    }
}

async fn get_bytes_single(
    client: &Client,
    url: &str,
    extra_headers: Option<&[(&str, &str)]>,
    on_bytes: Option<BytesProgressFn>,
) -> Result<Vec<u8>> {
    let headers = owned_headers(extra_headers);
    let resp = send(client, url, &headers, None).await?;
    let meter = ByteMeter::new(resp.content_length(), on_bytes);
    let bytes = read_body_vec(resp, &meter).await?;
    meter.finish();
    Ok(bytes)
}

async fn get_path_single(
    client: &Client,
    url: &str,
    extra_headers: Option<&[(&str, &str)]>,
    tmp: &Path,
    on_bytes: Option<BytesProgressFn>,
) -> Result<()> {
    let headers = owned_headers(extra_headers);
    let resp = send(client, url, &headers, None).await?;
    let meter = ByteMeter::new(resp.content_length(), on_bytes);
    stream_to_new_file(resp, tmp, &meter).await?;
    meter.finish();
    Ok(())
}

async fn get_bytes_ranged(
    client: &Client,
    url: &str,
    extra_headers: Option<&[(&str, &str)]>,
    total: u64,
    on_bytes: Option<BytesProgressFn>,
) -> Result<Vec<u8>> {
    let parts = plan_parts(total);
    let headers = owned_headers(extra_headers);
    let meter = ByteMeter::new(Some(total), on_bytes);
    let mut set = JoinSet::new();
    for (index, (start, end)) in parts.iter().copied().enumerate() {
        let client = client.clone();
        let url = url.to_string();
        let headers = headers.clone();
        let meter = meter.clone();
        set.spawn(async move {
            let data = download_part(&client, &url, &headers, start, end, &meter).await?;
            Ok::<(usize, Vec<u8>), anyhow::Error>((index, data))
        });
    }

    let mut slots: Vec<Option<Vec<u8>>> = vec![None; parts.len()];
    while let Some(joined) = set.join_next().await {
        match joined {
            Ok(Ok((index, data))) => slots[index] = Some(data),
            Ok(Err(err)) => {
                set.abort_all();
                return Err(err);
            }
            Err(err) => {
                set.abort_all();
                return Err(anyhow!("range worker panicked: {err}"));
            }
        }
    }

    let mut out = Vec::with_capacity(total as usize);
    for (i, slot) in slots.into_iter().enumerate() {
        let part = slot.ok_or_else(|| anyhow!("missing download part {i}"))?;
        out.extend_from_slice(&part);
    }
    meter.finish();
    Ok(out)
}

async fn get_path_ranged(
    client: &Client,
    url: &str,
    extra_headers: Option<&[(&str, &str)]>,
    tmp: &Path,
    total: u64,
    on_bytes: Option<BytesProgressFn>,
) -> Result<()> {
    {
        let file = tokio::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(tmp)
            .await?;
        file.set_len(total).await?;
    }
    let parts = plan_parts(total);
    let headers = owned_headers(extra_headers);
    let meter = ByteMeter::new(Some(total), on_bytes);
    let mut set = JoinSet::new();
    for (start, end) in parts {
        let client = client.clone();
        let url = url.to_string();
        let tmp = tmp.to_path_buf();
        let headers = headers.clone();
        let meter = meter.clone();
        set.spawn(async move {
            download_part_to_file(&client, &url, &headers, &tmp, start, end, &meter).await
        });
    }
    while let Some(joined) = set.join_next().await {
        match joined {
            Ok(Ok(())) => {}
            Ok(Err(err)) => {
                set.abort_all();
                return Err(err);
            }
            Err(err) => {
                set.abort_all();
                return Err(anyhow!("range worker panicked: {err}"));
            }
        }
    }
    meter.finish();
    Ok(())
}

async fn download_part(
    client: &Client,
    url: &str,
    extra_headers: &[(String, String)],
    start: u64,
    end: u64,
    meter: &ByteMeter,
) -> Result<Vec<u8>> {
    let expected = end - start + 1;
    let mut last_err = None;
    for attempt in 1..=PART_ATTEMPTS {
        let snap = meter.snapshot();
        match download_part_once(client, url, extra_headers, start, end, meter).await {
            Ok(bytes) => {
                if bytes.len() as u64 != expected {
                    anyhow::bail!(
                        "range {start}-{end} size mismatch: expected {expected}, got {}",
                        bytes.len()
                    );
                }
                return Ok(bytes);
            }
            Err(err) if err.downcast_ref::<RangeNotSupported>().is_some() => return Err(err),
            Err(err) => {
                meter.restore(snap);
                last_err = Some(err);
                if attempt < PART_ATTEMPTS {
                    tokio::time::sleep(Duration::from_millis(200 * attempt as u64)).await;
                }
            }
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("range {start}-{end} failed")))
}

async fn download_part_once(
    client: &Client,
    url: &str,
    extra_headers: &[(String, String)],
    start: u64,
    end: u64,
    meter: &ByteMeter,
) -> Result<Vec<u8>> {
    let range = format!("bytes={start}-{end}");
    let resp = send(client, url, extra_headers, Some(&range)).await?;
    match resp.status() {
        StatusCode::PARTIAL_CONTENT => read_body_vec(resp, meter).await,
        StatusCode::OK => Err(RangeNotSupported.into()),
        status => Err(anyhow!("HTTP {status} for range {range}: {url}")),
    }
}

async fn download_part_to_file(
    client: &Client,
    url: &str,
    extra_headers: &[(String, String)],
    tmp: &Path,
    start: u64,
    end: u64,
    meter: &ByteMeter,
) -> Result<()> {
    let expected = end - start + 1;
    let mut last_err = None;
    for attempt in 1..=PART_ATTEMPTS {
        let snap = meter.snapshot();
        match download_part_to_file_once(client, url, extra_headers, tmp, start, end, meter).await {
            Ok(written) => {
                if written != expected {
                    anyhow::bail!(
                        "range {start}-{end} size mismatch: expected {expected}, got {written}"
                    );
                }
                return Ok(());
            }
            Err(err) if err.downcast_ref::<RangeNotSupported>().is_some() => return Err(err),
            Err(err) => {
                meter.restore(snap);
                last_err = Some(err);
                if attempt < PART_ATTEMPTS {
                    tokio::time::sleep(Duration::from_millis(200 * attempt as u64)).await;
                }
            }
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("range {start}-{end} failed")))
}

async fn download_part_to_file_once(
    client: &Client,
    url: &str,
    extra_headers: &[(String, String)],
    tmp: &Path,
    start: u64,
    end: u64,
    meter: &ByteMeter,
) -> Result<u64> {
    let range = format!("bytes={start}-{end}");
    let resp = send(client, url, extra_headers, Some(&range)).await?;
    match resp.status() {
        StatusCode::PARTIAL_CONTENT => {
            let mut file = tokio::fs::OpenOptions::new().write(true).open(tmp).await?;
            file.seek(SeekFrom::Start(start)).await?;
            read_body_write(resp, &mut file, meter).await
        }
        StatusCode::OK => Err(RangeNotSupported.into()),
        status => Err(anyhow!("HTTP {status} for range {range}: {url}")),
    }
}

async fn send(
    client: &Client,
    url: &str,
    extra_headers: &[(String, String)],
    range: Option<&str>,
) -> Result<Response> {
    let mut req = client.get(url);
    for (k, v) in extra_headers {
        req = req.header(k.as_str(), v.as_str());
    }
    if let Some(range) = range {
        req = req
            .header(RANGE, range)
            .header(ACCEPT_ENCODING, HeaderValue::from_static("identity"));
    }
    let resp = tokio::time::timeout(HEADER_TIMEOUT, req.send())
        .await
        .map_err(|_| anyhow!("下载连接超时（{HEADER_TIMEOUT:?}）: {url}"))?
        .with_context(|| format!("请求失败: {url}"))?;
    if range.is_none() {
        resp.error_for_status()
            .with_context(|| format!("HTTP 错误: {url}"))
    } else {
        Ok(resp)
    }
}

async fn read_body_vec(response: Response, meter: &ByteMeter) -> Result<Vec<u8>> {
    let mut stream = response.bytes_stream();
    let mut buf = Vec::new();
    loop {
        match tokio::time::timeout(IDLE_TIMEOUT, stream.next()).await {
            Ok(Some(Ok(chunk))) => {
                meter.add(chunk.len() as u64);
                buf.extend_from_slice(&chunk);
            }
            Ok(Some(Err(e))) => return Err(e.into()),
            Ok(None) => break,
            Err(_) => anyhow::bail!("下载停滞：{IDLE_TIMEOUT:?} 内未收到数据"),
        }
    }
    Ok(buf)
}

async fn read_body_write<W: AsyncWriteExt + Unpin>(
    response: Response,
    writer: &mut W,
    meter: &ByteMeter,
) -> Result<u64> {
    let mut stream = response.bytes_stream();
    let mut written = 0u64;
    loop {
        match tokio::time::timeout(IDLE_TIMEOUT, stream.next()).await {
            Ok(Some(Ok(chunk))) => {
                writer.write_all(&chunk).await?;
                written += chunk.len() as u64;
                meter.add(chunk.len() as u64);
            }
            Ok(Some(Err(e))) => return Err(e.into()),
            Ok(None) => break,
            Err(_) => anyhow::bail!("下载停滞：{IDLE_TIMEOUT:?} 内未收到数据"),
        }
    }
    writer.flush().await?;
    Ok(written)
}

async fn stream_to_new_file(response: Response, tmp: &Path, meter: &ByteMeter) -> Result<()> {
    let mut file = tokio::fs::File::create(tmp).await?;
    read_body_write(response, &mut file, meter).await?;
    Ok(())
}

fn part_path(dest: &Path) -> std::path::PathBuf {
    let name = dest
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "download".into());
    dest.with_file_name(format!("{name}.amlpart"))
}

fn parse_content_range_total(value: Option<&HeaderValue>) -> Option<u64> {
    let text = value?.to_str().ok()?;
    let total = text.rsplit('/').next()?;
    if total == "*" {
        return None;
    }
    total.parse().ok()
}

/// Inclusive byte ranges covering [0, size).
pub fn plan_parts(size: u64) -> Vec<(u64, u64)> {
    if size == 0 {
        return Vec::new();
    }
    if size <= MULTI_THREAD_THRESHOLD {
        return vec![(0, size - 1)];
    }
    let mut n = size / MIN_PART_SIZE;
    n = n.clamp(2, MAX_PARTS as u64);
    let part = size / n;
    let mut out = Vec::with_capacity(n as usize);
    let mut start = 0u64;
    for i in 0..n {
        let end = if i + 1 == n {
            size - 1
        } else {
            (start + part).saturating_sub(1)
        };
        out.push((start, end));
        start = end + 1;
    }
    out
}

async fn sha1_file(path: &Path) -> Result<String> {
    use tokio::io::AsyncReadExt;
    let mut file = tokio::fs::File::open(path).await?;
    let mut hasher = Sha1::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = file.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn small_file_is_one_part() {
        assert_eq!(plan_parts(10 * 1024 * 1024), vec![(0, 10 * 1024 * 1024 - 1)]);
    }

    #[test]
    fn large_file_splits() {
        let size = 40 * 1024 * 1024;
        let parts = plan_parts(size);
        assert!(parts.len() >= 2);
        assert!(parts.len() <= MAX_PARTS);
        assert_eq!(parts.first().unwrap().0, 0);
        assert_eq!(parts.last().unwrap().1, size - 1);
        for window in parts.windows(2) {
            assert_eq!(window[0].1 + 1, window[1].0);
        }
        let covered: u64 = parts.iter().map(|(s, e)| e - s + 1).sum();
        assert_eq!(covered, size);
    }

    #[test]
    fn content_range_total() {
        let v = HeaderValue::from_static("bytes 0-0/12345678");
        assert_eq!(parse_content_range_total(Some(&v)), Some(12345678));
    }
}
