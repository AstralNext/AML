//! Local cache for project titles/summaries and detail body translations.

use anyhow::Result;
use chrono::Utc;
use sha2::{Digest, Sha256};
use sqlx::{Row, SqlitePool};

#[derive(Debug, Clone)]
pub struct ProjectI18nRow {
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

#[derive(Debug, Clone)]
pub struct ProjectI18nKey {
    pub platform: String,
    pub project_id: String,
}

#[derive(Debug, Clone)]
pub struct ProjectI18nUpsert {
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

#[derive(Debug, Clone)]
pub struct TextI18nRow {
    pub content_hash: String,
    pub platform: Option<String>,
    pub project_id: Option<String>,
    pub kind: String,
    pub source_text: String,
    pub zh_text: String,
    pub provider: String,
    pub updated_at: String,
}

pub async fn migrate_tables(pool: &SqlitePool) -> Result<()> {
    sqlx::query(
        r#"
		CREATE TABLE IF NOT EXISTS project_i18n (
			platform TEXT NOT NULL,
			project_id TEXT NOT NULL,
			slug TEXT,
			source_title TEXT NOT NULL,
			zh_title TEXT,
			source_summary TEXT,
			zh_summary TEXT,
			title_provider TEXT,
			summary_provider TEXT,
			title_confidence REAL NOT NULL DEFAULT 0.7,
			summary_confidence REAL NOT NULL DEFAULT 0.7,
			status TEXT NOT NULL DEFAULT 'auto',
			hit_count INTEGER NOT NULL DEFAULT 0,
			last_seen_at TEXT NOT NULL,
			updated_at TEXT NOT NULL,
			PRIMARY KEY (platform, project_id)
		);
		CREATE INDEX IF NOT EXISTS idx_project_i18n_slug ON project_i18n(slug);
		CREATE INDEX IF NOT EXISTS idx_project_i18n_zh ON project_i18n(zh_title);

		CREATE TABLE IF NOT EXISTS text_i18n (
			content_hash TEXT PRIMARY KEY NOT NULL,
			platform TEXT,
			project_id TEXT,
			kind TEXT NOT NULL,
			source_text TEXT NOT NULL,
			zh_text TEXT NOT NULL,
			provider TEXT NOT NULL,
			updated_at TEXT NOT NULL
		);
		"#,
    )
    .execute(pool)
    .await?;

    Ok(())
}

fn now_rfc3339() -> String {
    Utc::now().to_rfc3339()
}

fn map_row(r: &sqlx::sqlite::SqliteRow) -> Result<ProjectI18nRow> {
    Ok(ProjectI18nRow {
        platform: r.try_get("platform")?,
        project_id: r.try_get("project_id")?,
        slug: r.try_get("slug")?,
        source_title: r.try_get("source_title")?,
        zh_title: r.try_get("zh_title")?,
        source_summary: r.try_get("source_summary")?,
        zh_summary: r.try_get("zh_summary")?,
        title_provider: r.try_get("title_provider")?,
        summary_provider: r.try_get("summary_provider")?,
        title_confidence: r.try_get::<f64, _>("title_confidence").unwrap_or(0.7),
        summary_confidence: r.try_get::<f64, _>("summary_confidence").unwrap_or(0.7),
        status: r.try_get("status")?,
        hit_count: r.try_get::<i64, _>("hit_count").unwrap_or(0),
        last_seen_at: r.try_get("last_seen_at")?,
        updated_at: r.try_get("updated_at")?,
    })
}

pub async fn get_project_i18n(
    pool: &SqlitePool,
    keys: &[ProjectI18nKey],
) -> Result<Vec<ProjectI18nRow>> {
    if keys.is_empty() {
        return Ok(vec![]);
    }
    let mut out = Vec::with_capacity(keys.len());
    for key in keys {
        let row = sqlx::query(
            r#"SELECT * FROM project_i18n WHERE platform = ? AND project_id = ?"#,
        )
        .bind(&key.platform)
        .bind(&key.project_id)
        .fetch_optional(pool)
        .await?;
        if let Some(r) = row {
            out.push(map_row(&r)?);
        }
    }
    Ok(out)
}

pub async fn upsert_project_i18n(pool: &SqlitePool, rows: &[ProjectI18nUpsert]) -> Result<()> {
    let now = now_rfc3339();
    for u in rows {
        let existing = sqlx::query(
            r#"SELECT source_title, zh_title, status, hit_count, last_seen_at
			   FROM project_i18n WHERE platform = ? AND project_id = ?"#,
        )
        .bind(&u.platform)
        .bind(&u.project_id)
        .fetch_optional(pool)
        .await?;

        let (hit_count, last_seen_at, preserve_zh_title) = if let Some(ref e) = existing {
            let status: String = e.try_get("status").unwrap_or_else(|_| "auto".into());
            let preserve = status == "reviewed" || status == "manual";
            (
                e.try_get::<i64, _>("hit_count").unwrap_or(0),
                e.try_get::<String, _>("last_seen_at")
                    .unwrap_or_else(|_| now.clone()),
                preserve,
            )
        } else {
            (0_i64, now.clone(), false)
        };

        let mut status = u.status.clone().unwrap_or_else(|| "auto".to_string());
        if let Some(ref e) = existing {
            let old_title: String = e.try_get("source_title").unwrap_or_default();
            if !old_title.is_empty() && old_title != u.source_title && !preserve_zh_title {
                status = "stale".to_string();
            }
            if preserve_zh_title {
                status = e.try_get("status").unwrap_or_else(|_| "reviewed".into());
            }
        }

        let zh_title = if preserve_zh_title {
            existing
                .as_ref()
                .and_then(|e| e.try_get::<Option<String>, _>("zh_title").ok())
                .flatten()
                .or_else(|| u.zh_title.clone())
        } else {
            u.zh_title.clone()
        };

        let title_confidence = u.title_confidence.unwrap_or(0.7);
        let summary_confidence = u.summary_confidence.unwrap_or(0.7);

        sqlx::query(
            r#"
			INSERT INTO project_i18n (
				platform, project_id, slug, source_title, zh_title,
				source_summary, zh_summary, title_provider, summary_provider,
				title_confidence, summary_confidence, status, hit_count,
				last_seen_at, updated_at
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(platform, project_id) DO UPDATE SET
				slug = COALESCE(excluded.slug, project_i18n.slug),
				source_title = excluded.source_title,
				zh_title = CASE
					WHEN project_i18n.status IN ('reviewed', 'manual')
					THEN project_i18n.zh_title
					ELSE excluded.zh_title
				END,
				source_summary = COALESCE(excluded.source_summary, project_i18n.source_summary),
				zh_summary = COALESCE(excluded.zh_summary, project_i18n.zh_summary),
				title_provider = CASE
					WHEN project_i18n.status IN ('reviewed', 'manual')
					THEN project_i18n.title_provider
					ELSE excluded.title_provider
				END,
				summary_provider = COALESCE(excluded.summary_provider, project_i18n.summary_provider),
				title_confidence = CASE
					WHEN project_i18n.status IN ('reviewed', 'manual')
					THEN project_i18n.title_confidence
					ELSE excluded.title_confidence
				END,
				summary_confidence = COALESCE(excluded.summary_confidence, project_i18n.summary_confidence),
				status = CASE
					WHEN project_i18n.status IN ('reviewed', 'manual')
					THEN project_i18n.status
					ELSE excluded.status
				END,
				updated_at = excluded.updated_at
			"#,
        )
        .bind(&u.platform)
        .bind(&u.project_id)
        .bind(&u.slug)
        .bind(&u.source_title)
        .bind(&zh_title)
        .bind(&u.source_summary)
        .bind(&u.zh_summary)
        .bind(&u.title_provider)
        .bind(&u.summary_provider)
        .bind(title_confidence)
        .bind(summary_confidence)
        .bind(&status)
        .bind(hit_count)
        .bind(&last_seen_at)
        .bind(&now)
        .execute(pool)
        .await?;

        if status == "stale" && zh_title.as_ref().is_some_and(|t| !t.is_empty()) {
            sqlx::query(
                r#"UPDATE project_i18n SET status = 'auto' WHERE platform = ? AND project_id = ?"#,
            )
            .bind(&u.platform)
            .bind(&u.project_id)
            .execute(pool)
            .await?;
        }
    }
    Ok(())
}

pub fn text_content_hash(
    platform: Option<&str>,
    project_id: Option<&str>,
    kind: &str,
    source: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(platform.unwrap_or("").as_bytes());
    hasher.update(b"|");
    hasher.update(project_id.unwrap_or("").as_bytes());
    hasher.update(b"|");
    hasher.update(kind.as_bytes());
    hasher.update(b"|");
    hasher.update(source.as_bytes());
    hex::encode(hasher.finalize())
}

pub async fn get_text_i18n(pool: &SqlitePool, content_hash: &str) -> Result<Option<TextI18nRow>> {
    let row = sqlx::query(r#"SELECT * FROM text_i18n WHERE content_hash = ?"#)
        .bind(content_hash)
        .fetch_optional(pool)
        .await?;
    Ok(match row {
        Some(r) => Some(TextI18nRow {
            content_hash: r.try_get("content_hash")?,
            platform: r.try_get("platform")?,
            project_id: r.try_get("project_id")?,
            kind: r.try_get("kind")?,
            source_text: r.try_get("source_text")?,
            zh_text: r.try_get("zh_text")?,
            provider: r.try_get("provider")?,
            updated_at: r.try_get("updated_at")?,
        }),
        None => None,
    })
}

pub async fn upsert_text_i18n(pool: &SqlitePool, row: &TextI18nRow) -> Result<()> {
    sqlx::query(
        r#"
		INSERT INTO text_i18n (
			content_hash, platform, project_id, kind, source_text, zh_text, provider, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(content_hash) DO UPDATE SET
			zh_text = excluded.zh_text,
			provider = excluded.provider,
			updated_at = excluded.updated_at
		"#,
    )
    .bind(&row.content_hash)
    .bind(&row.platform)
    .bind(&row.project_id)
    .bind(&row.kind)
    .bind(&row.source_text)
    .bind(&row.zh_text)
    .bind(&row.provider)
    .bind(&row.updated_at)
    .execute(pool)
    .await?;
    Ok(())
}
