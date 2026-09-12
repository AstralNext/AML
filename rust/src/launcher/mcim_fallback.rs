use anyhow::{anyhow, Result};
use reqwest::Client;
use serde::de::DeserializeOwned;

use crate::config::mcim_url_candidates;

fn apply_headers(
    mut req: reqwest::RequestBuilder,
    extra_headers: Option<&[(&str, &str)]>,
) -> reqwest::RequestBuilder {
    if let Some(headers) = extra_headers {
        for (k, v) in headers {
            req = req.header(*k, *v);
        }
    }
    req
}

/// GET JSON from [url], trying MCIM mirror when the official host fails.
pub async fn client_get_json<T: DeserializeOwned>(
    client: &Client,
    url: &str,
) -> Result<T> {
    client_get_json_with_headers(client, url, None).await
}

/// GET JSON with optional headers (e.g. CurseForge `x-api-key`).
pub async fn client_get_json_with_headers<T: DeserializeOwned>(
    client: &Client,
    url: &str,
    extra_headers: Option<&[(&str, &str)]>,
) -> Result<T> {
    let mut last_err = None;
    for candidate in mcim_url_candidates(url) {
        let req = apply_headers(client.get(&candidate), extra_headers);
        match req.send().await {
            Ok(resp) => match resp.error_for_status() {
                Ok(ok) => match ok.json::<T>().await {
                    Ok(value) => return Ok(value),
                    Err(e) => last_err = Some(e.into()),
                },
                Err(e) => last_err = Some(e.into()),
            },
            Err(e) => last_err = Some(e.into()),
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("GET failed: {url}")))
}

/// POST JSON body, official-first with MCIM fallback.
pub async fn client_post_json<T: DeserializeOwned>(
    client: &Client,
    url: &str,
    body: &impl serde::Serialize,
) -> Result<T> {
    client_post_json_with_headers(client, url, body, None).await
}

/// POST JSON with optional headers (e.g. CurseForge `x-api-key`).
pub async fn client_post_json_with_headers<T: DeserializeOwned>(
    client: &Client,
    url: &str,
    body: &impl serde::Serialize,
    extra_headers: Option<&[(&str, &str)]>,
) -> Result<T> {
    let mut last_err = None;
    for candidate in mcim_url_candidates(url) {
        let req = apply_headers(client.post(&candidate).json(body), extra_headers);
        match req.send().await {
            Ok(resp) => match resp.error_for_status() {
                Ok(ok) => match ok.json::<T>().await {
                    Ok(value) => return Ok(value),
                    Err(e) => last_err = Some(e.into()),
                },
                Err(e) => last_err = Some(e.into()),
            },
            Err(e) => last_err = Some(e.into()),
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("POST failed: {url}")))
}
