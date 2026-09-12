//! Minecraft Server List Ping (modern JSON + legacy §).
//! Description is returned as raw JSON text for the UI to render as MOTD.

use anyhow::{Result, anyhow};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::value::RawValue;
use std::time::Duration;
use tokio::net::ToSocketAddrs;
use tokio::select;

const MAX_MINECRAFT_STATUS_STRING_LENGTH: usize = 32_767;
const MAX_MODERN_STATUS_PACKET_LENGTH: usize = MAX_MINECRAFT_STATUS_STRING_LENGTH + 4;
const MAX_LEGACY_STATUS_UTF16_LENGTH: usize = MAX_MINECRAFT_STATUS_STRING_LENGTH;
const SERVER_STATUS_TIMEOUT: Duration = Duration::from_secs(5);

fn cap_length(length: usize, max_length: usize, context: &'static str) -> Result<usize> {
    if length > max_length {
        return Err(anyhow!("{context}"));
    }
    Ok(length)
}

/// `null` → `T::default()` (many servers send `"sample": null`).
fn null_default<'de, D, T>(deserializer: D) -> std::result::Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Default + Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

#[derive(Deserialize, Serialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ServerStatus {
    #[serde(default)]
    pub description: Option<Box<RawValue>>,
    #[serde(default)]
    pub players: Option<ServerPlayers>,
    #[serde(default)]
    pub version: Option<ServerVersion>,
    #[serde(default)]
    pub favicon: Option<String>,
    #[serde(default)]
    pub enforces_secure_chat: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ping: Option<i64>,
}

/// Normalize a Minecraft status / servers.dat icon into a clean data URL.
/// Vanilla often embeds MIME-wrapped base64 with newlines; strip those so Flutter can decode.
pub fn normalize_favicon(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    let (prefix, payload) = if let Some(rest) = trimmed.strip_prefix("data:") {
        let Some(comma) = rest.find(',') else {
            return None;
        };
        let meta = &rest[..comma];
        // data:image/png;base64,XXXX  (or ;base64 missing — still treat as base64)
        let header = if meta.to_ascii_lowercase().contains("base64") {
            format!("data:{meta},")
        } else {
            format!("data:{meta};base64,")
        };
        (header, &rest[comma + 1..])
    } else {
        ("data:image/png;base64,".to_string(), trimmed)
    };

    let cleaned: String = payload.chars().filter(|c| !c.is_whitespace()).collect();
    if cleaned.is_empty() {
        return None;
    }
    // Rough validity: base64 alphabet only
    if !cleaned
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=')
    {
        return None;
    }
    Some(format!("{prefix}{cleaned}"))
}

fn attach_normalized_favicon(mut status: ServerStatus) -> ServerStatus {
    if let Some(raw) = status.favicon.take() {
        let raw_len = raw.len();
        let prefix: String = raw.chars().take(48).collect();
        match normalize_favicon(&raw) {
            Some(clean) => {
                eprintln!(
                    "[AML ping] favicon ok: raw_len={raw_len} clean_len={} prefix={prefix:?}…",
                    clean.len()
                );
                status.favicon = Some(clean);
            }
            None => {
                eprintln!(
                    "[AML ping] favicon dropped by normalize: raw_len={raw_len} prefix={prefix:?}…"
                );
                status.favicon = None;
            }
        }
    } else {
        eprintln!("[AML ping] favicon: absent in status JSON");
    }
    status
}

fn log_status_summary(address: &str, legacy: bool, status: &ServerStatus) {
    let motd = status
        .description
        .as_ref()
        .map(|v| {
            let s = v.get();
            let preview: String = s.chars().take(120).collect();
            format!("len={} preview={preview:?}", s.len())
        })
        .unwrap_or_else(|| "none".into());
    let fav = status
        .favicon
        .as_ref()
        .map(|f| format!("len={}", f.len()))
        .unwrap_or_else(|| "none".into());
    let players = status
        .players
        .as_ref()
        .map(|p| format!("{}/{}", p.online, p.max))
        .unwrap_or_else(|| "?".into());
    let ver = status
        .version
        .as_ref()
        .map(|v| format!("{} proto={}", v.name, v.protocol))
        .unwrap_or_else(|| "?".into());
    eprintln!(
        "[AML ping] ok address={address:?} legacy={legacy} players={players} version={ver} ping_ms={:?} motd={motd} favicon={fav}",
        status.ping
    );
}

#[derive(Deserialize, Serialize, Debug, Clone)]
pub struct ServerPlayers {
    #[serde(default)]
    pub max: i32,
    #[serde(default)]
    pub online: i32,
    #[serde(default, deserialize_with = "null_default")]
    pub sample: Vec<ServerGameProfile>,
}

#[derive(Deserialize, Serialize, Debug, Clone, Default)]
pub struct ServerGameProfile {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
}

#[derive(Deserialize, Serialize, Debug, Clone, Default)]
pub struct ServerVersion {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub protocol: i32,
    #[serde(skip_deserializing, default)]
    pub legacy: bool,
}

pub async fn get_server_status(
    address: &impl ToSocketAddrs,
    original_address: (&str, u16),
    protocol_version: Option<i32>,
    legacy: bool,
) -> Result<ServerStatus> {
    select! {
        res = async {
            if legacy {
                let v = protocol_version.unwrap_or(74).clamp(0, 255) as u8;
                legacy::status(address, original_address, Some(v)).await
            } else {
                modern::status(address, original_address, protocol_version.map(|v| v as u32)).await
            }
        } => res,
        _ = tokio::time::sleep(SERVER_STATUS_TIMEOUT) => Err(anyhow!(
            "ping of {}:{} timed out",
            original_address.0,
            original_address.1
        )),
    }
}

/// Parse address, optional SRV, then ping. Falls back to the original host if SRV/connect fails.
pub async fn ping_server(
    address: &str,
    protocol_version: Option<i32>,
    legacy: bool,
) -> Result<ServerStatus> {
    eprintln!(
        "[AML ping] start address={address:?} protocol={protocol_version:?} legacy={legacy}"
    );
    let (host, port) = super::server_address::parse_server_address(address).map_err(|e| {
        eprintln!("[AML ping] parse address failed: {e:#}");
        e
    })?;
    eprintln!("[AML ping] parsed host={host:?} port={port}");
    let (resolved_host, resolved_port) =
        match super::server_address::resolve_server_address(&host, port).await {
            Ok(v) => {
                eprintln!(
                    "[AML ping] resolved {host}:{port} → {}:{}",
                    v.0, v.1
                );
                v
            }
            Err(e) => {
                eprintln!("[AML ping] resolve failed (using typed host): {e:#}");
                (host.clone(), port)
            }
        };

    // Prefer resolved endpoint; fall back to the typed address (game client does A/AAAA itself).
    let first = get_server_status(
        &(resolved_host.as_str(), resolved_port),
        (&host, port),
        protocol_version,
        legacy,
    )
    .await;

    let status = if first.is_ok() || (resolved_host == host && resolved_port == port) {
        match first {
            Ok(s) => Ok(attach_normalized_favicon(s)),
            Err(e) => {
                eprintln!(
                    "[AML ping] connect/status failed {resolved_host}:{resolved_port} → {e:#}"
                );
                Err(e)
            }
        }
    } else {
        eprintln!(
            "[AML ping] retry original host={host:?} port={port} after resolved endpoint failed"
        );
        match get_server_status(
            &(host.as_str(), port),
            (&host, port),
            protocol_version,
            legacy,
        )
        .await
        {
            Ok(s) => Ok(attach_normalized_favicon(s)),
            Err(e) => {
                eprintln!("[AML ping] original host also failed: {e:#}");
                Err(e)
            }
        }
    };

    if let Ok(ref s) = status {
        log_status_summary(address, legacy, s);
    }
    status
}

fn parse_status_payload(json_response: &[u8]) -> Result<ServerStatus> {
    eprintln!(
        "[AML ping] status JSON bytes={} preview={:?}",
        json_response.len(),
        String::from_utf8_lossy(&json_response[..json_response.len().min(160)])
    );
    match serde_json::from_slice::<ServerStatus>(json_response) {
        Ok(status) => {
            eprintln!("[AML ping] status JSON deserialized (strict)");
            Ok(status)
        }
        Err(strict_err) => {
            eprintln!("[AML ping] strict deserialize failed, salvage: {strict_err}");
            // Some servers send quirky JSON; salvage MOTD / players / version.
            let value: serde_json::Value = serde_json::from_slice(json_response)
                .map_err(|_| anyhow!("invalid status json: {strict_err}"))?;
            Ok(ServerStatus {
                description: value
                    .get("description")
                    .and_then(|d| RawValue::from_string(d.to_string()).ok()),
                players: value.get("players").and_then(|p| {
                    Some(ServerPlayers {
                        max: p.get("max").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
                        online: p.get("online").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
                        sample: p
                            .get("sample")
                            .and_then(|s| s.as_array())
                            .map(|arr| {
                                arr.iter()
                                    .filter_map(|item| {
                                        Some(ServerGameProfile {
                                            id: item
                                                .get("id")
                                                .and_then(|v| v.as_str())
                                                .unwrap_or("")
                                                .to_owned(),
                                            name: item
                                                .get("name")
                                                .and_then(|v| v.as_str())?
                                                .to_owned(),
                                        })
                                    })
                                    .collect()
                            })
                            .unwrap_or_default(),
                    })
                }),
                version: value.get("version").map(|v| ServerVersion {
                    name: v
                        .get("name")
                        .and_then(|n| n.as_str())
                        .unwrap_or("")
                        .to_owned(),
                    protocol: v
                        .get("protocol")
                        .and_then(|n| n.as_i64())
                        .unwrap_or(0) as i32,
                    legacy: false,
                }),
                favicon: value
                    .get("favicon")
                    .and_then(|f| f.as_str())
                    .and_then(normalize_favicon),
                enforces_secure_chat: value
                    .get("enforcesSecureChat")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false),
                ping: None,
            })
        }
    }
}

mod modern {
    use super::ServerStatus;
    use anyhow::{Result, anyhow};
    use std::time::Instant;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpStream, ToSocketAddrs};

    pub async fn status(
        address: &impl ToSocketAddrs,
        original_address: (&str, u16),
        protocol_version: Option<u32>,
    ) -> Result<ServerStatus> {
        let mut stream = TcpStream::connect(address).await?;
        stream.set_nodelay(true)?;
        handshake(&mut stream, original_address, protocol_version).await?;
        let mut result = status_body(&mut stream).await?;
        result.ping = ping(&mut stream).await.ok();
        Ok(result)
    }

    async fn handshake(
        stream: &mut TcpStream,
        original_address: (&str, u16),
        protocol_version: Option<u32>,
    ) -> Result<()> {
        let (host, port) = original_address;
        let protocol_version = protocol_version.map_or(-1, |x| x as i32);

        const PACKET_ID: i32 = 0;
        const NEXT_STATE: i32 = 1;

        let packet_size = varint::get_byte_size(PACKET_ID)
            + varint::get_byte_size(protocol_version)
            + varint::get_byte_size(host.len() as i32)
            + host.len()
            + std::mem::size_of::<u16>()
            + varint::get_byte_size(NEXT_STATE);

        let mut packet_buffer =
            Vec::with_capacity(varint::get_byte_size(packet_size as i32) + packet_size);

        varint::write(&mut packet_buffer, packet_size as i32);
        varint::write(&mut packet_buffer, PACKET_ID);
        varint::write(&mut packet_buffer, protocol_version);
        varint::write(&mut packet_buffer, host.len() as i32);
        packet_buffer.extend_from_slice(host.as_bytes());
        packet_buffer.extend_from_slice(&port.to_be_bytes());
        varint::write(&mut packet_buffer, NEXT_STATE);

        stream.write_all(&packet_buffer).await?;
        stream.flush().await?;
        Ok(())
    }

    async fn status_body(stream: &mut TcpStream) -> Result<ServerStatus> {
        stream.write_all(&[0x01, 0x00]).await?;
        stream.flush().await?;

        let packet_length = cap_varint_length(
            varint::read(stream).await?,
            super::MAX_MODERN_STATUS_PACKET_LENGTH,
            "invalid status response packet length",
        )?;

        let mut packet_stream = stream.take(packet_length as u64);
        let packet_id = varint::read(&mut packet_stream).await?;
        if packet_id != 0x00 {
            return Err(anyhow!("unexpected status response"));
        }
        let response_length = cap_varint_length(
            varint::read(&mut packet_stream).await?,
            super::MAX_MINECRAFT_STATUS_STRING_LENGTH,
            "invalid status response length",
        )?;
        let mut json_response = vec![0_u8; response_length];
        packet_stream.read_exact(&mut json_response).await?;

        if packet_stream.limit() > 0 {
            tokio::io::copy(&mut packet_stream, &mut tokio::io::sink()).await?;
        }

        super::parse_status_payload(&json_response)
    }

    fn cap_varint_length(length: i32, max_length: usize, context: &'static str) -> Result<usize> {
        if length < 0 {
            return Err(anyhow!("{context}"));
        }
        super::cap_length(length as usize, max_length, context)
    }

    async fn ping(stream: &mut TcpStream) -> Result<i64> {
        let ping_magic = chrono::Utc::now().timestamp_millis();
        let start_time = Instant::now();
        stream.write_all(&[0x09, 0x01]).await?;
        stream.write_i64(ping_magic).await?;
        stream.flush().await?;

        let mut response_prefix = [0_u8; 2];
        stream.read_exact(&mut response_prefix).await?;
        let response_magic = stream.read_i64().await?;
        if response_prefix != [0x09, 0x01] || response_magic != ping_magic {
            return Err(anyhow!("unexpected ping response"));
        }
        Ok(start_time.elapsed().as_millis() as i64)
    }

    mod varint {
        use std::io;
        use tokio::io::{AsyncRead, AsyncReadExt};

        const MAX_VARINT_SIZE: usize = 5;
        const DATA_BITS_MASK: u32 = 0x7f;
        const CONT_BIT_MASK_U8: u8 = 0x80;
        const CONT_BIT_MASK_U32: u32 = CONT_BIT_MASK_U8 as u32;
        const DATA_BITS_PER_BYTE: usize = 7;

        pub fn get_byte_size(x: i32) -> usize {
            let x = x as u32;
            for size in 1..MAX_VARINT_SIZE {
                if (x & (u32::MAX << (size * DATA_BITS_PER_BYTE))) == 0 {
                    return size;
                }
            }
            MAX_VARINT_SIZE
        }

        pub fn write(out: &mut Vec<u8>, value: i32) {
            let mut value = value as u32;
            while value >= CONT_BIT_MASK_U32 {
                out.push(((value & DATA_BITS_MASK) | CONT_BIT_MASK_U32) as u8);
                value >>= DATA_BITS_PER_BYTE;
            }
            out.push(value as u8);
        }

        pub async fn read<R: AsyncRead + Unpin>(reader: &mut R) -> io::Result<i32> {
            let mut result = 0u32;
            let mut shift = 0usize;
            loop {
                let b = reader.read_u8().await?;
                result |= (b as u32 & DATA_BITS_MASK) << (shift * DATA_BITS_PER_BYTE);
                shift += 1;
                if shift > MAX_VARINT_SIZE {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "VarInt too big"));
                }
                if b & CONT_BIT_MASK_U8 == 0 {
                    return Ok(result as i32);
                }
            }
        }
    }
}

mod legacy {
    use super::{ServerPlayers, ServerStatus, ServerVersion};
    use anyhow::{Result, anyhow};
    use serde_json::value::to_raw_value;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpStream, ToSocketAddrs};

    pub async fn status(
        address: &impl ToSocketAddrs,
        original_address: (&str, u16),
        protocol_version: Option<u8>,
    ) -> Result<ServerStatus> {
        let protocol_version = protocol_version.unwrap_or(74);

        let mut packet = vec![0xfe];
        if protocol_version >= 47 {
            packet.push(0x01);
        }
        if protocol_version >= 73 {
            packet.push(0xfa);
            write_legacy(&mut packet, "MC|PingHost");

            let (host, port) = original_address;
            let len_index = packet.len();
            packet.push(protocol_version);
            write_legacy(&mut packet, host);
            packet.extend_from_slice(&(port as u32).to_be_bytes());
            packet.splice(
                len_index..len_index,
                ((packet.len() - len_index) as u16).to_be_bytes(),
            );
        }

        let mut stream = TcpStream::connect(address).await?;
        stream.write_all(&packet).await?;
        stream.flush().await?;

        let packet_id = stream.read_u8().await?;
        if packet_id != 0xff {
            return Err(anyhow!("unexpected legacy status response"));
        }

        let data_length = super::cap_length(
            stream.read_u16().await? as usize,
            super::MAX_LEGACY_STATUS_UTF16_LENGTH,
            "invalid legacy status response length",
        )?;
        let data_byte_length = data_length
            .checked_mul(2)
            .ok_or_else(|| anyhow!("invalid legacy status response length"))?;
        let mut data = vec![0u8; data_byte_length];
        stream.read_exact(&mut data).await?;
        drop(stream);

        let data = String::from_utf16_lossy(
            &data
                .chunks_exact(2)
                .map(|a| u16::from_be_bytes([a[0], a[1]]))
                .collect::<Vec<u16>>(),
        );
        let mut ancient_server = false;
        let mut parts = data.split('\0');
        if parts.next() != Some("§1") {
            ancient_server = true;
            parts = data.split('§');
        }

        Ok(ServerStatus {
            version: (!ancient_server).then(|| ServerVersion {
                protocol: parts.next().and_then(|x| x.parse().ok()).unwrap_or(0),
                name: parts.next().unwrap_or("").to_owned(),
                legacy: true,
            }),
            description: parts.next().and_then(|x| to_raw_value(x).ok()),
            players: Some(ServerPlayers {
                online: parts.next().and_then(|x| x.parse().ok()).unwrap_or(-1),
                max: parts.next().and_then(|x| x.parse().ok()).unwrap_or(-1),
                sample: vec![],
            }),
            favicon: None,
            enforces_secure_chat: false,
            ping: None,
        })
    }

    fn write_legacy(out: &mut Vec<u8>, text: &str) {
        let encoded = text.encode_utf16().collect::<Vec<_>>();
        out.extend_from_slice(&(encoded.len() as u16).to_be_bytes());
        out.extend(encoded.into_iter().flat_map(u16::to_be_bytes));
    }
}
