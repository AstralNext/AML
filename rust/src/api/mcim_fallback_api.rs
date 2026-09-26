//! Discover 侧 MCIM 回退 HTTP（API JSON 与图片/文件字节下载）。
//!
//! URL 候选生成统一走 `config::mcim_url_candidates`（单一事实来源），
//! Dart 侧 `McimFallbackHttp` 只是本模块的薄壳。

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use anyhow::{anyhow, Result};
use tokio::sync::Semaphore;

use crate::config::mcim_url_candidates;

/// 与旧 Dart 实现一致的下载并发闸门：Discover 列表滚动时避免同时打开
/// 几十条 TLS 连接。
static DOWNLOAD_SLOTS: OnceLock<Arc<Semaphore>> = OnceLock::new();

fn download_slots() -> Arc<Semaphore> {
    DOWNLOAD_SLOTS.get_or_init(|| Arc::new(Semaphore::new(8))).clone()
}

fn http_client() -> Result<reqwest::Client> {
    Ok(crate::config::apply_proxy(reqwest::Client::builder()).build()?)
}

#[derive(Debug, Clone)]
pub struct McimHttpResponse {
    pub status_code: i32,
    pub body: Vec<u8>,
    /// 保留响应头（Dart 侧 `http.Response.bytes` 需要 content-type 来解码 JSON）。
    pub headers: HashMap<String, String>,
}

/// GET 请求，官方优先 + MCIM/CDN 镜像回退。
///
/// 语义与旧 Dart `McimFallbackHttp.get` 一致：任一候选 2xx 即返回；
/// 全部非 2xx 时返回最后一个响应；全部网络错误才抛异常。
pub async fn mcim_get(
    url: String,
    headers: Option<HashMap<String, String>>,
    timeout_secs: u64,
) -> Result<McimHttpResponse> {
    let client = http_client()?;
    let mut last: Option<McimHttpResponse> = None;
    let mut last_err: Option<anyhow::Error> = None;
    for candidate in mcim_url_candidates(&url) {
        let mut req = client.get(&candidate).timeout(Duration::from_secs(timeout_secs));
        if let Some(h) = &headers {
            for (k, v) in h {
                req = req.header(k.as_str(), v.as_str());
            }
        }
        match req.send().await {
            Ok(resp) => {
                let status = resp.status().as_u16() as i32;
                let header_map: HashMap<String, String> = resp
                    .headers()
                    .iter()
                    .filter_map(|(k, v)| v.to_str().ok().map(|s| (k.as_str().to_string(), s.to_string())))
                    .collect();
                match resp.bytes().await {
                    Ok(body) => {
                        let r = McimHttpResponse {
                            status_code: status,
                            body: body.to_vec(),
                            headers: header_map,
                        };
                        if (200..300).contains(&status) {
                            return Ok(r);
                        }
                        last = Some(r);
                    }
                    Err(e) => last_err = Some(anyhow!("{e}")),
                }
            }
            Err(e) => last_err = Some(anyhow!("{e}")),
        }
    }
    if let Some(r) = last {
        return Ok(r);
    }
    Err(last_err.unwrap_or_else(|| anyhow!("请求失败: {url}")))
}

/// 下载字节（图标等），官方 + 镜像回退，全局 8 并发闸门。
/// 任一候选 2xx 且内容非空即成功；否则全部尝试完后抛异常。
pub async fn mcim_get_bytes(
    url: String,
    headers: Option<HashMap<String, String>>,
    timeout_secs: u64,
) -> Result<Vec<u8>> {
    let _permit = download_slots()
        .acquire_owned()
        .await
        .map_err(|e| anyhow!("下载闸门关闭: {e}"))?;
    let client = http_client()?;
    let mut last_err: Option<anyhow::Error> = None;
    for candidate in mcim_url_candidates(&url) {
        let mut req = client.get(&candidate).timeout(Duration::from_secs(timeout_secs));
        if let Some(h) = &headers {
            for (k, v) in h {
                req = req.header(k.as_str(), v.as_str());
            }
        }
        match req.send().await {
            Ok(resp) => {
                let status = resp.status().as_u16();
                if (200..300).contains(&status) {
                    match resp.bytes().await {
                        Ok(b) if !b.is_empty() => return Ok(b.to_vec()),
                        Ok(_) => {}
                        Err(e) => last_err = Some(anyhow!("{e}")),
                    }
                }
            }
            Err(e) => last_err = Some(anyhow!("{e}")),
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("下载失败: {url}")))
}
