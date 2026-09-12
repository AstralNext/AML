use anyhow::{Result, anyhow};
use std::net::{Ipv4Addr, Ipv6Addr};
use tokio::sync::Semaphore;

/// Parse `host`, `host:port`, or `[ipv6]:port` (default port 25565).
pub fn parse_server_address(address: &str) -> Result<(String, u16)> {
    let address = address.trim();
    if address.is_empty() {
        return Err(anyhow!("empty server address"));
    }

    let (host, port_str) = if address.starts_with('[') {
        let close = address
            .rfind(']')
            .ok_or_else(|| anyhow!("invalid bracketed host/port: {address}"))?;
        let host = &address[1..close];
        if close + 1 == address.len() {
            (host, "")
        } else if address.as_bytes().get(close + 1) != Some(&b':') {
            return Err(anyhow!("only a colon may follow a close bracket: {address}"));
        } else {
            (&address[1..close], &address[close + 2..])
        }
    } else if let Some(colon) = address.find(':') {
        if address[colon + 1..].contains(':') {
            (address, "")
        } else {
            (&address[..colon], &address[colon + 1..])
        }
    } else {
        (address, "")
    };

    if host.is_empty() {
        return Err(anyhow!("empty host in address: {address}"));
    }

    let port = if port_str.is_empty() {
        25565
    } else {
        if port_str.starts_with('+') {
            return Err(anyhow!("unparsable port number: {port_str}"));
        }
        port_str
            .parse::<u16>()
            .map_err(|_| anyhow!("unparsable port number: {port_str}"))?
    };

    Ok((host.to_owned(), port))
}

/// Resolve DNS SRV `_minecraft._tcp.{host}` when port is the default and host is not an IP.
/// On any SRV/DNS failure, falls back to the original host:port (same as the game client).
pub async fn resolve_server_address(host: &str, port: u16) -> Result<(String, u16)> {
    static SIMULTANEOUS_DNS_QUERIES: Semaphore = Semaphore::const_new(24);

    if port != 25565
        || host.parse::<Ipv4Addr>().is_ok()
        || host.parse::<Ipv6Addr>().is_ok()
    {
        return Ok((host.to_owned(), port));
    }

    let Ok(_permit) = SIMULTANEOUS_DNS_QUERIES.acquire().await else {
        return Ok((host.to_owned(), port));
    };

    let Ok(builder) = hickory_resolver::TokioResolver::builder_tokio() else {
        return Ok((host.to_owned(), port));
    };
    let resolver = builder.build();

    match resolver.srv_lookup(format!("_minecraft._tcp.{host}")).await {
        Ok(lookup) => Ok(lookup
            .into_iter()
            .next()
            .map(|r| {
                let target = r.target().to_string();
                let target = target.trim_end_matches('.').to_owned();
                (target, r.port())
            })
            .unwrap_or_else(|| (host.to_owned(), port))),
        Err(_) => Ok((host.to_owned(), port)),
    }
}
