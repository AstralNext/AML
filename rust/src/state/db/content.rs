use anyhow::Result;
use sqlx::SqlitePool;

#[derive(Debug, Clone)]
pub struct ContentEntry {
    pub id: String,
    pub instance_id: String,
    pub relative_path: String,
    pub file_name: String,
    pub project_type: String,
    pub project_id: Option<String>,
    pub version_id: Option<String>,
    pub version_number: Option<String>,
    pub version_name: Option<String>,
    pub project_title: Option<String>,
    pub project_icon_url: Option<String>,
    pub author: Option<String>,
    pub author_avatar_url: Option<String>,
    pub author_id: Option<String>,
    pub author_type: Option<String>,
    pub update_version_id: Option<String>,
    pub enabled: bool,
    pub sha1: Option<String>,
    pub size_bytes: Option<i64>,
    pub added_at: String,
    pub pending: bool,
    pub download_url: Option<String>,
}

#[derive(sqlx::FromRow)]
struct ContentRow {
    id: String,
    instance_id: String,
    relative_path: String,
    file_name: String,
    project_type: String,
    project_id: Option<String>,
    version_id: Option<String>,
    version_number: Option<String>,
    version_name: Option<String>,
    project_title: Option<String>,
    project_icon_url: Option<String>,
    author: Option<String>,
    author_avatar_url: Option<String>,
    author_id: Option<String>,
    author_type: Option<String>,
    update_version_id: Option<String>,
    enabled: i64,
    sha1: Option<String>,
    size_bytes: Option<i64>,
    added_at: String,
    pending: i64,
    download_url: Option<String>,
}

impl ContentRow {
    fn into_entry(self) -> ContentEntry {
        ContentEntry {
            id: self.id,
            instance_id: self.instance_id,
            relative_path: self.relative_path,
            file_name: self.file_name,
            project_type: self.project_type,
            project_id: self.project_id,
            version_id: self.version_id,
            version_number: self.version_number,
            version_name: self.version_name,
            project_title: self.project_title,
            project_icon_url: self.project_icon_url,
            author: self.author,
            author_avatar_url: self.author_avatar_url,
            author_id: self.author_id,
            author_type: self.author_type,
            update_version_id: self.update_version_id,
            enabled: self.enabled != 0,
            sha1: self.sha1,
            size_bytes: self.size_bytes,
            added_at: self.added_at,
            pending: self.pending != 0,
            download_url: self.download_url,
        }
    }
}

pub async fn upsert_content_entry(pool: &SqlitePool, entry: &ContentEntry) -> Result<()> {
    sqlx::query(
        r#"
		INSERT INTO instance_content (
			id, instance_id, relative_path, file_name, project_type,
			project_id, version_id, version_number, version_name,
			project_title, project_icon_url, author, author_avatar_url,
			author_id, author_type, update_version_id, enabled, sha1, size_bytes, added_at,
			pending, download_url
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(instance_id, relative_path) DO UPDATE SET
			file_name = excluded.file_name,
			project_type = excluded.project_type,
			project_id = COALESCE(excluded.project_id, instance_content.project_id),
			version_id = COALESCE(excluded.version_id, instance_content.version_id),
			version_number = COALESCE(excluded.version_number, instance_content.version_number),
			version_name = COALESCE(excluded.version_name, instance_content.version_name),
			project_title = COALESCE(excluded.project_title, instance_content.project_title),
			project_icon_url = COALESCE(excluded.project_icon_url, instance_content.project_icon_url),
			author = COALESCE(excluded.author, instance_content.author),
			author_avatar_url = COALESCE(excluded.author_avatar_url, instance_content.author_avatar_url),
			author_id = COALESCE(excluded.author_id, instance_content.author_id),
			author_type = COALESCE(excluded.author_type, instance_content.author_type),
			update_version_id = excluded.update_version_id,
			enabled = excluded.enabled,
			sha1 = COALESCE(excluded.sha1, instance_content.sha1),
			size_bytes = COALESCE(excluded.size_bytes, instance_content.size_bytes),
			pending = excluded.pending,
			download_url = COALESCE(excluded.download_url, instance_content.download_url)
		"#,
    )
    .bind(&entry.id)
    .bind(&entry.instance_id)
    .bind(&entry.relative_path)
    .bind(&entry.file_name)
    .bind(&entry.project_type)
    .bind(&entry.project_id)
    .bind(&entry.version_id)
    .bind(&entry.version_number)
    .bind(&entry.version_name)
    .bind(&entry.project_title)
    .bind(&entry.project_icon_url)
    .bind(&entry.author)
    .bind(&entry.author_avatar_url)
    .bind(&entry.author_id)
    .bind(&entry.author_type)
    .bind(&entry.update_version_id)
    .bind(if entry.enabled { 1 } else { 0 })
    .bind(&entry.sha1)
    .bind(entry.size_bytes)
    .bind(&entry.added_at)
    .bind(if entry.pending { 1 } else { 0 })
    .bind(&entry.download_url)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn list_content_for_instance(
    pool: &SqlitePool,
    instance_id: &str,
) -> Result<Vec<ContentEntry>> {
    let rows = sqlx::query_as::<_, ContentRow>(
        r#"SELECT * FROM instance_content WHERE instance_id = ? ORDER BY file_name COLLATE NOCASE"#,
    )
    .bind(instance_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(ContentRow::into_entry).collect())
}

pub async fn list_content_by_project(
    pool: &SqlitePool,
    instance_id: &str,
    project_id: &str,
) -> Result<Vec<ContentEntry>> {
    let rows = sqlx::query_as::<_, ContentRow>(
        r#"SELECT * FROM instance_content
		WHERE instance_id = ? AND project_id = ?
		ORDER BY file_name COLLATE NOCASE"#,
    )
    .bind(instance_id)
    .bind(project_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(ContentRow::into_entry).collect())
}

pub async fn update_content_path_and_enabled(
    pool: &SqlitePool,
    instance_id: &str,
    old_relative_path: &str,
    new_relative_path: &str,
    file_name: &str,
    enabled: bool,
) -> Result<()> {
    sqlx::query(
        r#"UPDATE instance_content
		SET relative_path = ?, file_name = ?, enabled = ?
		WHERE instance_id = ? AND relative_path = ?"#,
    )
    .bind(new_relative_path)
    .bind(file_name)
    .bind(if enabled { 1 } else { 0 })
    .bind(instance_id)
    .bind(old_relative_path)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn remove_content_entry(
    pool: &SqlitePool,
    instance_id: &str,
    relative_path: &str,
) -> Result<()> {
    sqlx::query(r#"DELETE FROM instance_content WHERE instance_id = ? AND relative_path = ?"#)
        .bind(instance_id)
        .bind(relative_path)
        .execute(pool)
        .await?;
    Ok(())
}
