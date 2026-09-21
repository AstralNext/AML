use anyhow::Result;
use sqlx::{Row, SqlitePool};

/// Record a multiplayer join for home recent-servers / world list sorting.
pub async fn record_server_join(
    pool: &SqlitePool,
    instance_id: &str,
    address: &str,
) -> Result<()> {
    let Ok((host, port)) =
        crate::launcher::server_address::parse_server_address(address)
    else {
        return Ok(());
    };
    let now = chrono::Utc::now().timestamp_millis();
    sqlx::query(
        r#"
		INSERT INTO server_join_log (instance_id, host, port, join_time_ms)
		VALUES (?, ?, ?, ?)
		ON CONFLICT (instance_id, host, port) DO UPDATE SET
			join_time_ms = excluded.join_time_ms
		"#,
    )
    .bind(instance_id)
    .bind(&host)
    .bind(port as i64)
    .bind(now)
    .execute(pool)
    .await?;
    Ok(())
}

/// `(host, port) → join_time_ms` for an instance.
pub async fn get_server_joins(
    pool: &SqlitePool,
    instance_id: &str,
) -> Result<std::collections::HashMap<(String, u16), i64>> {
    let rows = sqlx::query(
        "SELECT host, port, join_time_ms FROM server_join_log WHERE instance_id = ?",
    )
    .bind(instance_id)
    .fetch_all(pool)
    .await?;

    let mut out = std::collections::HashMap::new();
    for row in rows {
        let host: String = row.try_get("host")?;
        let port: i64 = row.try_get("port")?;
        let ms: i64 = row.try_get("join_time_ms")?;
        if port >= 0 && port <= u16::MAX as i64 {
            out.insert((host, port as u16), ms);
        }
    }
    Ok(out)
}
