use anyhow::{anyhow, Result};
use sqlx::SqlitePool;

use crate::state::models::YggdrasilService;

pub async fn list_yggdrasil_services(pool: &SqlitePool) -> Result<Vec<YggdrasilService>> {
    let rows = sqlx::query_as::<_, YggdrasilServiceRow>(
        "SELECT id, name, api_url, builtin FROM yggdrasil_services ORDER BY builtin DESC, name",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(YggdrasilServiceRow::into_service)
        .collect())
}

pub async fn get_yggdrasil_service(pool: &SqlitePool, id: &str) -> Result<YggdrasilService> {
    let row = sqlx::query_as::<_, YggdrasilServiceRow>(
        "SELECT id, name, api_url, builtin FROM yggdrasil_services WHERE id = ?",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?
    .ok_or_else(|| anyhow!("Yggdrasil 服务不存在: {id}"))?;
    Ok(row.into_service())
}

pub async fn upsert_yggdrasil_service(
    pool: &SqlitePool,
    id: &str,
    name: &str,
    api_url: &str,
) -> Result<YggdrasilService> {
    sqlx::query(
        r#"INSERT INTO yggdrasil_services (id, name, api_url, builtin)
		VALUES (?, ?, ?, 0)
		ON CONFLICT(id) DO UPDATE SET name = excluded.name, api_url = excluded.api_url"#,
    )
    .bind(id)
    .bind(name)
    .bind(api_url)
    .execute(pool)
    .await?;
    get_yggdrasil_service(pool, id).await
}

pub async fn remove_yggdrasil_service(pool: &SqlitePool, id: &str) -> Result<()> {
    let in_use: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM accounts WHERE auth_server_id = ?")
        .bind(id)
        .fetch_one(pool)
        .await?;
    if in_use > 0 {
        return Err(anyhow!("该服务仍有 {in_use} 个账号，无法删除"));
    }
    let result = sqlx::query("DELETE FROM yggdrasil_services WHERE id = ? AND builtin = 0")
        .bind(id)
        .execute(pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(anyhow!("内置服务不能删除"));
    }
    Ok(())
}

#[derive(sqlx::FromRow)]
struct YggdrasilServiceRow {
    id: String,
    name: String,
    api_url: String,
    builtin: i64,
}

impl YggdrasilServiceRow {
    fn into_service(self) -> YggdrasilService {
        YggdrasilService {
            id: self.id,
            name: self.name,
            api_url: self.api_url,
            builtin: self.builtin != 0,
        }
    }
}
