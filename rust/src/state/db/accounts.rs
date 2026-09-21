use anyhow::{anyhow, Result};
use sqlx::SqlitePool;

use crate::state::models::{offline_uuid, Account};

pub async fn list_accounts(pool: &SqlitePool) -> Result<Vec<Account>> {
    let rows = sqlx::query_as::<_, AccountRow>(
        r#"SELECT id, kind, username, uuid, access_token, refresh_token, client_token,
			auth_server_id, expires_at, active
			FROM accounts ORDER BY rowid ASC"#,
    )
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(AccountRow::into_account).collect())
}

pub async fn get_active_account(pool: &SqlitePool) -> Result<Option<Account>> {
    let row = sqlx::query_as::<_, AccountRow>(
        r#"SELECT id, kind, username, uuid, access_token, refresh_token, client_token,
			auth_server_id, expires_at, active
			FROM accounts WHERE active = 1 LIMIT 1"#,
    )
    .fetch_optional(pool)
    .await?;
    Ok(row.map(AccountRow::into_account))
}

pub async fn upsert_offline_account(pool: &SqlitePool, username: &str) -> Result<Account> {
    let uuid = offline_uuid(username);
    let id = format!("offline:{uuid}");

    sqlx::query("UPDATE accounts SET active = 0")
        .execute(pool)
        .await?;

    sqlx::query(
        r#"INSERT INTO accounts (id, kind, username, uuid, access_token, active)
		VALUES (?, 'offline', ?, ?, '0', 1)
		ON CONFLICT(id) DO UPDATE SET username = excluded.username, active = 1"#,
    )
    .bind(&id)
    .bind(username)
    .bind(&uuid)
    .execute(pool)
    .await?;

    Ok(Account {
        id,
        kind: "offline".into(),
        username: username.into(),
        uuid,
        access_token: Some("0".into()),
        refresh_token: None,
        client_token: None,
        auth_server_id: None,
        expires_at: None,
        active: true,
    })
}

pub async fn upsert_msa_account(
    pool: &SqlitePool,
    username: &str,
    uuid: &str,
    access_token: &str,
    refresh_token: Option<&str>,
    expires_at: Option<&str>,
) -> Result<Account> {
    let id = format!("msa:{uuid}");
    sqlx::query("UPDATE accounts SET active = 0")
        .execute(pool)
        .await?;
    sqlx::query(
		r#"INSERT INTO accounts (id, kind, username, uuid, access_token, refresh_token, expires_at, active)
		VALUES (?, 'msa', ?, ?, ?, ?, ?, 1)
		ON CONFLICT(id) DO UPDATE SET
			username = excluded.username,
			access_token = excluded.access_token,
			refresh_token = excluded.refresh_token,
			expires_at = excluded.expires_at,
			active = 1"#,
	)
	.bind(&id)
	.bind(username)
	.bind(uuid)
	.bind(access_token)
	.bind(refresh_token)
	.bind(expires_at)
	.execute(pool)
	.await?;

    Ok(Account {
        id,
        kind: "msa".into(),
        username: username.into(),
        uuid: uuid.into(),
        access_token: Some(access_token.into()),
        refresh_token: refresh_token.map(|s| s.to_string()),
        client_token: None,
        auth_server_id: None,
        expires_at: expires_at.map(|s| s.to_string()),
        active: true,
    })
}

pub async fn upsert_yggdrasil_account(
    pool: &SqlitePool,
    service_id: &str,
    username: &str,
    uuid: &str,
    access_token: &str,
    client_token: &str,
    expires_at: &str,
) -> Result<Account> {
    let id = format!("yggdrasil:{service_id}:{uuid}");
    sqlx::query("UPDATE accounts SET active = 0")
        .execute(pool)
        .await?;
    sqlx::query(
        r#"INSERT INTO accounts (
			id, kind, username, uuid, access_token, client_token,
			auth_server_id, expires_at, active
		) VALUES (?, 'yggdrasil', ?, ?, ?, ?, ?, ?, 1)
		ON CONFLICT(id) DO UPDATE SET
			username = excluded.username,
			access_token = excluded.access_token,
			client_token = excluded.client_token,
			auth_server_id = excluded.auth_server_id,
			expires_at = excluded.expires_at,
			active = 1"#,
    )
    .bind(&id)
    .bind(username)
    .bind(uuid)
    .bind(access_token)
    .bind(client_token)
    .bind(service_id)
    .bind(expires_at)
    .execute(pool)
    .await?;
    Ok(Account {
        id,
        kind: "yggdrasil".into(),
        username: username.into(),
        uuid: uuid.into(),
        access_token: Some(access_token.into()),
        refresh_token: None,
        client_token: Some(client_token.into()),
        auth_server_id: Some(service_id.into()),
        expires_at: Some(expires_at.into()),
        active: true,
    })
}

pub async fn update_yggdrasil_account_token(
    pool: &SqlitePool,
    id: &str,
    access_token: &str,
    client_token: &str,
    expires_at: &str,
) -> Result<()> {
    sqlx::query(
        "UPDATE accounts SET access_token = ?, client_token = ?, expires_at = ? WHERE id = ?",
    )
    .bind(access_token)
    .bind(client_token)
    .bind(expires_at)
    .bind(id)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn set_active_account(pool: &SqlitePool, id: &str) -> Result<()> {
    sqlx::query("UPDATE accounts SET active = 0")
        .execute(pool)
        .await?;
    let result = sqlx::query("UPDATE accounts SET active = 1 WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    if result.rows_affected() == 0 {
        return Err(anyhow!("account not found: {id}"));
    }
    Ok(())
}

pub async fn remove_account(pool: &SqlitePool, id: &str) -> Result<()> {
    sqlx::query("DELETE FROM accounts WHERE id = ?")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}

#[derive(sqlx::FromRow)]
struct AccountRow {
    id: String,
    kind: String,
    username: String,
    uuid: String,
    access_token: Option<String>,
    refresh_token: Option<String>,
    client_token: Option<String>,
    auth_server_id: Option<String>,
    expires_at: Option<String>,
    active: i64,
}

impl AccountRow {
    fn into_account(self) -> Account {
        Account {
            id: self.id,
            kind: self.kind,
            username: self.username,
            uuid: self.uuid,
            access_token: self.access_token,
            refresh_token: self.refresh_token,
            client_token: self.client_token,
            auth_server_id: self.auth_server_id,
            expires_at: self.expires_at,
            active: self.active != 0,
        }
    }
}
