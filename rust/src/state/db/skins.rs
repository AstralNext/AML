use anyhow::Result;
use sqlx::{Row, SqlitePool};

#[derive(Debug, Clone)]
pub struct CustomSkinRow {
    pub texture_key: String,
    pub name: Option<String>,
    pub variant: String,
    pub cape_id: Option<String>,
    pub file_path: String,
}

#[derive(Debug, Clone)]
pub struct SkinPreference {
    pub texture_key: String,
    pub variant: String,
    pub cape_id: Option<String>,
}

pub async fn list_custom_skins(pool: &SqlitePool, user_uuid: &str) -> Result<Vec<CustomSkinRow>> {
    let rows = sqlx::query(
        r#"SELECT texture_key, name, variant, cape_id, file_path
		FROM custom_skins WHERE user_uuid = ?
		ORDER BY display_order ASC, texture_key ASC"#,
    )
    .bind(user_uuid)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| CustomSkinRow {
            texture_key: r.get("texture_key"),
            name: r.get("name"),
            variant: r.get("variant"),
            cape_id: r.get("cape_id"),
            file_path: r.get("file_path"),
        })
        .collect())
}

pub async fn get_custom_skin(
    pool: &SqlitePool,
    user_uuid: &str,
    texture_key: &str,
) -> Result<Option<CustomSkinRow>> {
    let row = sqlx::query(
        r#"SELECT texture_key, name, variant, cape_id, file_path
		FROM custom_skins WHERE user_uuid = ? AND texture_key = ?"#,
    )
    .bind(user_uuid)
    .bind(texture_key)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|r| CustomSkinRow {
        texture_key: r.get("texture_key"),
        name: r.get("name"),
        variant: r.get("variant"),
        cape_id: r.get("cape_id"),
        file_path: r.get("file_path"),
    }))
}

pub async fn upsert_custom_skin(
    pool: &SqlitePool,
    user_uuid: &str,
    texture_key: &str,
    name: Option<&str>,
    variant: &str,
    cape_id: Option<&str>,
    file_path: &str,
) -> Result<()> {
    sqlx::query(
		r#"INSERT INTO custom_skins (user_uuid, texture_key, name, variant, cape_id, file_path, display_order)
		VALUES (?, ?, ?, ?, ?, ?, 0)
		ON CONFLICT(user_uuid, texture_key) DO UPDATE SET
			name = excluded.name,
			variant = excluded.variant,
			cape_id = excluded.cape_id,
			file_path = excluded.file_path"#,
	)
	.bind(user_uuid)
	.bind(texture_key)
	.bind(name)
	.bind(variant)
	.bind(cape_id)
	.bind(file_path)
	.execute(pool)
	.await?;
    Ok(())
}

pub async fn delete_custom_skin(
    pool: &SqlitePool,
    user_uuid: &str,
    texture_key: &str,
) -> Result<()> {
    sqlx::query(r#"DELETE FROM custom_skins WHERE user_uuid = ? AND texture_key = ?"#)
        .bind(user_uuid)
        .bind(texture_key)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn get_skin_preference(
    pool: &SqlitePool,
    user_uuid: &str,
) -> Result<Option<SkinPreference>> {
    let row = sqlx::query(
        r#"SELECT texture_key, variant, cape_id FROM skin_preferences WHERE user_uuid = ?"#,
    )
    .bind(user_uuid)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|r| SkinPreference {
        texture_key: r.get("texture_key"),
        variant: r.get("variant"),
        cape_id: r.get("cape_id"),
    }))
}

pub async fn set_skin_preference(
    pool: &SqlitePool,
    user_uuid: &str,
    texture_key: &str,
    variant: &str,
    cape_id: Option<&str>,
) -> Result<()> {
    sqlx::query(
        r#"INSERT INTO skin_preferences (user_uuid, texture_key, variant, cape_id)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(user_uuid) DO UPDATE SET
			texture_key = excluded.texture_key,
			variant = excluded.variant,
			cape_id = excluded.cape_id"#,
    )
    .bind(user_uuid)
    .bind(texture_key)
    .bind(variant)
    .bind(cape_id)
    .execute(pool)
    .await?;
    Ok(())
}
