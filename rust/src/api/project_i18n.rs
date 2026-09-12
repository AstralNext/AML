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
