use std::collections::HashMap;
use std::time::Duration;

use crate::state;
use crate::state::project_i18n::{self, ProjectI18nKey, ProjectI18nUpsert, TextI18nRow};

#[derive(Clone, Debug)]
pub struct ProjectI18nKeyDto {
    pub platform: String,
    pub project_id: String,
}

#[derive(Clone, Debug)]
pub struct ProjectI18nDto {
    pub platform: String,
    pub project_id: String,
    pub slug: Option<String>,
    pub source_title: String,
    pub zh_title: Option<String>,
    pub source_summary: Option<String>,
    pub zh_summary: Option<String>,
    pub title_provider: Option<String>,
    pub summary_provider: Option<String>,
    pub title_confidence: f64,
    pub summary_confidence: f64,
    pub status: String,
    pub hit_count: i64,
    pub last_seen_at: String,
    pub updated_at: String,
}

impl From<project_i18n::ProjectI18nRow> for ProjectI18nDto {
    fn from(r: project_i18n::ProjectI18nRow) -> Self {
        Self {
            platform: r.platform,
            project_id: r.project_id,
            slug: r.slug,
            source_title: r.source_title,
            zh_title: r.zh_title,
            source_summary: r.source_summary,
            zh_summary: r.zh_summary,
            title_provider: r.title_provider,
            summary_provider: r.summary_provider,
            title_confidence: r.title_confidence,
            summary_confidence: r.summary_confidence,
            status: r.status,
            hit_count: r.hit_count,
            last_seen_at: r.last_seen_at,
            updated_at: r.updated_at,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ProjectI18nUpsertDto {
    pub platform: String,
    pub project_id: String,
    pub slug: Option<String>,
    pub source_title: String,
    pub zh_title: Option<String>,
    pub source_summary: Option<String>,
    pub zh_summary: Option<String>,
    pub title_provider: Option<String>,
    pub summary_provider: Option<String>,
    pub title_confidence: Option<f64>,
    pub summary_confidence: Option<f64>,
    pub status: Option<String>,
}

#[derive(Clone, Debug)]
pub struct TextI18nDto {
    pub content_hash: String,
    pub platform: Option<String>,
    pub project_id: Option<String>,
    pub kind: String,
    pub source_text: String,
    pub zh_text: String,
    pub provider: String,
    pub updated_at: String,
}

pub async fn get_project_i18n(
    keys: Vec<ProjectI18nKeyDto>,
) -> Result<Vec<ProjectI18nDto>, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let keys: Vec<ProjectI18nKey> = keys
        .into_iter()
        .map(|k| ProjectI18nKey {
            platform: k.platform,
            project_id: k.project_id,
        })
        .collect();
    let rows = project_i18n::get_project_i18n(&state.pool, &keys)
        .await
        .map_err(|e| e.to_string())?;
    Ok(rows.into_iter().map(ProjectI18nDto::from).collect())
}

pub async fn upsert_project_i18n(rows: Vec<ProjectI18nUpsertDto>) -> Result<(), String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let rows: Vec<ProjectI18nUpsert> = rows
        .into_iter()
        .map(|u| ProjectI18nUpsert {
            platform: u.platform,
            project_id: u.project_id,
            slug: u.slug,
            source_title: u.source_title,
            zh_title: u.zh_title,
            source_summary: u.source_summary,
            zh_summary: u.zh_summary,
            title_provider: u.title_provider,
            summary_provider: u.summary_provider,
            title_confidence: u.title_confidence,
            summary_confidence: u.summary_confidence,
            status: u.status,
        })
        .collect();
    project_i18n::upsert_project_i18n(&state.pool, &rows)
        .await
        .map_err(|e| e.to_string())
}

pub fn text_i18n_hash(
    platform: Option<String>,
    project_id: Option<String>,
    kind: String,
    source_text: String,
) -> String {
    project_i18n::text_content_hash(
        platform.as_deref(),
        project_id.as_deref(),
        &kind,
        &source_text,
    )
}

pub async fn get_text_i18n(content_hash: String) -> Result<Option<TextI18nDto>, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let row = project_i18n::get_text_i18n(&state.pool, &content_hash)
        .await
        .map_err(|e| e.to_string())?;
    Ok(row.map(|r| TextI18nDto {
        content_hash: r.content_hash,
        platform: r.platform,
        project_id: r.project_id,
        kind: r.kind,
        source_text: r.source_text,
        zh_text: r.zh_text,
        provider: r.provider,
        updated_at: r.updated_at,
    }))
}

pub async fn upsert_text_i18n(
    content_hash: String,
    platform: Option<String>,
    project_id: Option<String>,
    kind: String,
    source_text: String,
    zh_text: String,
    provider: String,
) -> Result<(), String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let row = TextI18nRow {
        content_hash,
        platform,
        project_id,
        kind,
        source_text,
        zh_text,
        provider,
        updated_at: chrono::Utc::now().to_rfc3339(),
    };
    project_i18n::upsert_text_i18n(&state.pool, &row)
        .await
        .map_err(|e| e.to_string())
}

#[derive(Clone, Debug)]
pub struct TranslationCacheStatsDto {
    pub project_entries: i64,
    pub text_entries: i64,
    pub total_hits: i64,
    pub project_bytes: i64,
    pub text_bytes: i64,
}

impl TranslationCacheStatsDto {
    pub fn total_bytes(&self) -> i64 {
        self.project_bytes.saturating_add(self.text_bytes)
    }
}

/// Aggregate persistent translation cache stats for settings UI.
pub async fn translation_cache_stats() -> Result<TranslationCacheStatsDto, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let pool = &state.pool;

    let project_entries = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM project_i18n")
        .fetch_one(pool)
        .await
        .map_err(|e| e.to_string())?;
    let text_entries = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM text_i18n")
        .fetch_one(pool)
        .await
        .map_err(|e| e.to_string())?;

    let total_hits =
        sqlx::query_scalar::<_, i64>("SELECT COALESCE(SUM(hit_count), 0) FROM project_i18n")
            .fetch_one(pool)
            .await
            .map_err(|e| e.to_string())?;

    let project_bytes = sqlx::query_scalar::<_, i64>(
        r#"SELECT COALESCE(SUM(
			LENGTH(COALESCE(source_title, ''))
			+ LENGTH(COALESCE(zh_title, ''))
			+ LENGTH(COALESCE(source_summary, ''))
			+ LENGTH(COALESCE(zh_summary, ''))
			+ LENGTH(COALESCE(slug, ''))
		), 0) FROM project_i18n"#,
    )
    .fetch_one(pool)
    .await
    .map_err(|e| e.to_string())?;

    let text_bytes = sqlx::query_scalar::<_, i64>(
        r#"SELECT COALESCE(SUM(
			LENGTH(COALESCE(source_text, ''))
			+ LENGTH(COALESCE(zh_text, ''))
		), 0) FROM text_i18n"#,
    )
    .fetch_one(pool)
    .await
    .map_err(|e| e.to_string())?;

    Ok(TranslationCacheStatsDto {
        project_entries,
        text_entries,
        total_hits,
        project_bytes,
        text_bytes,
    })
}

pub async fn clear_project_i18n_cache() -> Result<i64, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let pool = &state.pool;
    let before = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM project_i18n")
        .fetch_one(pool)
        .await
        .map_err(|e| e.to_string())?;
    sqlx::query("DELETE FROM project_i18n")
        .execute(pool)
        .await
        .map_err(|e| e.to_string())?;
    Ok(before)
}

pub async fn clear_text_i18n_cache() -> Result<i64, String> {
    let state = state::try_state().map_err(|e| e.to_string())?;
    let before = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM text_i18n")
        .fetch_one(&state.pool)
        .await
        .map_err(|e| e.to_string())?;
    sqlx::query("DELETE FROM text_i18n")
        .execute(&state.pool)
        .await
        .map_err(|e| e.to_string())?;
    Ok(before)
}

/// Clear project titles/summaries and body cache.
pub async fn clear_all_translation_caches() -> Result<i64, String> {
    let a = clear_project_i18n_cache().await?;
    let b = clear_text_i18n_cache().await?;
    Ok(a.saturating_add(b))
}

#[derive(Clone, Debug)]
pub struct LocalizeProjectInputDto {
    /// modrinth: 原始 project id；curseforge: 纯数字 mod id（不带 `cf-` 前缀）。
    pub project_id: String,
    pub slug: Option<String>,
    pub source_title: String,
    pub source_summary: String,
    /// 调用方已知的高质量中文标题（MCDB 词条），优先于本地缓存。
    pub hint_zh_title: Option<String>,
}

#[derive(Clone, Debug)]
pub struct LocalizedProjectDto {
    pub project_id: String,
    pub zh_title: Option<String>,
    pub zh_summary: Option<String>,
}

fn nonempty_trimmed(s: Option<&str>) -> Option<&str> {
    s.map(str::trim).filter(|s| !s.is_empty())
}

/// MCIM 社区简介批量翻译（尽力而为，任何失败都返回空 map，不影响调用方）。
///
/// - modrinth: `POST /translate/modrinth` `{"project_ids":[...]}`
/// - curseforge: `POST /translate/curseforge` `{"modids":[...]}`
async fn mcim_batch_translate(
    platform: &str,
    ids: &[String],
) -> HashMap<String, String> {
    let mut out = HashMap::new();
    if ids.is_empty() {
        return out;
    }

    let client = match crate::config::apply_proxy(
        reqwest::Client::builder()
            .user_agent("AML-App/1.0")
            .timeout(Duration::from_secs(15)),
    )
    .build()
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[mcim] http client build failed: {e}");
            return out;
        }
    };

    let body: Result<serde_json::Value, reqwest::Error> = async {
        if platform == "curseforge" {
            let modids: Vec<i64> = ids.iter().filter_map(|s| s.parse::<i64>().ok()).collect();
            if modids.is_empty() {
                return Ok(serde_json::Value::Null);
            }
            let resp = client
                .post("https://mod.mcimirror.top/translate/curseforge")
                .json(&serde_json::json!({ "modids": modids }))
                .send()
                .await?
                .error_for_status()?;
            Ok(resp.json().await?)
        } else {
            let resp = client
                .post("https://mod.mcimirror.top/translate/modrinth")
                .json(&serde_json::json!({ "project_ids": ids }))
                .send()
                .await?
                .error_for_status()?;
            Ok(resp.json().await?)
        }
    }
    .await;

    let value = match body {
        Ok(v) => v,
        Err(e) => {
            eprintln!("[mcim] batch translate failed: {e}");
            return out;
        }
    };

    if let serde_json::Value::Array(arr) = value {
        for item in arr {
            let translated = nonempty_trimmed(item.get("translated").and_then(|v| v.as_str()))
                .unwrap_or("")
                .to_string();
            if translated.is_empty() {
                continue;
            }
            let id = if platform == "curseforge" {
                match item.get("modid") {
                    Some(serde_json::Value::String(s)) => s.clone(),
                    Some(serde_json::Value::Number(n)) => n.to_string(),
                    _ => continue,
                }
            } else {
                match item.get("project_id").and_then(|v| v.as_str()) {
                    Some(s) => s.to_string(),
                    None => continue,
                }
            };
            out.insert(id, translated);
        }
    }

    out
}

/// 批量本地化项目标题/简介：本地 `project_i18n` 命中直返，
/// 缺失简介走 MCIM 批量接口，新译文回写本地缓存。
///
/// 标题只来自 MCDB 词条（[LocalizeProjectInputDto::hint_zh_title]）或本地缓存，
/// 不发起标题网络请求；`include_summary=false` 时为纯本地读取（无网络）。
pub async fn localize_projects(
    platform: String,
    include_summary: bool,
    items: Vec<LocalizeProjectInputDto>,
) -> Result<Vec<LocalizedProjectDto>, String> {
    if items.is_empty() {
        return Ok(vec![]);
    }
    let state = state::try_state().map_err(|e| e.to_string())?;
    let pool = &state.pool;

    let keys: Vec<ProjectI18nKey> = items
        .iter()
        .map(|i| ProjectI18nKey {
            platform: platform.clone(),
            project_id: i.project_id.clone(),
        })
        .collect();
    let cached_rows = project_i18n::get_project_i18n(pool, &keys)
        .await
        .map_err(|e| e.to_string())?;
    let cached: HashMap<String, project_i18n::ProjectI18nRow> = cached_rows
        .into_iter()
        .map(|r| (r.project_id.clone(), r))
        .collect();

    let missing_summary: Vec<String> = if include_summary {
        items
            .iter()
            .filter(|i| {
                nonempty_trimmed(
                    cached
                        .get(&i.project_id)
                        .and_then(|r| r.zh_summary.as_deref()),
                )
                .is_none()
            })
            .map(|i| i.project_id.clone())
            .collect()
    } else {
        Vec::new()
    };
    let fresh = if missing_summary.is_empty() {
        HashMap::new()
    } else {
        mcim_batch_translate(&platform, &missing_summary).await
    };

    let mut upserts = Vec::new();
    let mut results = Vec::with_capacity(items.len());

    for item in &items {
        let cached_row = cached.get(&item.project_id);
        let hint =
            nonempty_trimmed(item.hint_zh_title.as_deref()).map(str::to_string);
        let fresh_summary = fresh.get(&item.project_id).cloned();

        let zh_title = hint.clone().or_else(|| {
            cached_row
                .and_then(|r| nonempty_trimmed(r.zh_title.as_deref()).map(str::to_string))
        });
        let zh_summary = fresh_summary.clone().or_else(|| {
            cached_row
                .and_then(|r| nonempty_trimmed(r.zh_summary.as_deref()).map(str::to_string))
        });

        // 仅在带来新信息时回写，避免纯浏览产生 SQLite 写放大。
        if hint.is_some() || fresh_summary.is_some() {
            upserts.push(ProjectI18nUpsert {
                platform: platform.clone(),
                project_id: item.project_id.clone(),
                slug: item.slug.clone(),
                source_title: item.source_title.clone(),
                zh_title: zh_title.clone(),
                source_summary: Some(item.source_summary.clone()),
                // 无新简介时传 None，upsert SQL 的 COALESCE 会保留旧值。
                zh_summary: fresh_summary.clone(),
                title_provider: if hint.is_some() {
                    Some("mcdb".to_string())
                } else {
                    cached_row.and_then(|r| r.title_provider.clone())
                },
                summary_provider: if fresh_summary.is_some() {
                    Some("mcim".to_string())
                } else {
                    None
                },
                title_confidence: Some(
                    if hint.is_some() {
                        1.0
                    } else {
                        cached_row.map(|r| r.title_confidence).unwrap_or(0.7)
                    },
                ),
                summary_confidence: Some(if fresh_summary.is_some() {
                    1.0
                } else {
                    cached_row
                        .map(|r| r.summary_confidence)
                        .unwrap_or(0.7)
                }),
                status: None,
            });
        }

        results.push(LocalizedProjectDto {
            project_id: item.project_id.clone(),
            zh_title,
            zh_summary,
        });
    }

    if !upserts.is_empty() {
        if let Err(e) = project_i18n::upsert_project_i18n(pool, &upserts).await {
            eprintln!("[project_i18n] upsert during localize failed: {e}");
        }
    }

    Ok(results)
}
