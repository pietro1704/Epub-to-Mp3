//! TLS/proxy WebSocket transport and upgrade/error mapping.
use super::{EdgeError, EdgeTransport, TransportFuture};
use http::Request;
use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};
use tokio_tungstenite::{
    client_async_tls_with_config, tungstenite::client::IntoClientRequest, Connector,
};
use url::Url;

#[derive(Default)]
pub struct WebSocketTransport;

impl EdgeTransport for WebSocketTransport {
    fn connect<'a>(&'a self, request: Request<()>) -> TransportFuture<'a> {
        Box::pin(async move {
            let request = websocket_upgrade_request(request)?;
            let mut roots = rustls::RootCertStore::empty();
            let certificate_result = rustls_native_certs::load_native_certs();
            for certificate in certificate_result.certs {
                roots
                    .add(certificate)
                    .map_err(|error| EdgeError::Transport(error.to_string()))?;
            }
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let mut tls_config = rustls::ClientConfig::builder()
                .with_root_certificates(roots)
                .with_no_client_auth();
            tls_config.alpn_protocols = vec![b"http/1.1".to_vec()];
            let tls_connector = Connector::Rustls(std::sync::Arc::new(tls_config));
            let host = request
                .uri()
                .host()
                .ok_or_else(|| EdgeError::Url("Edge WebSocket URL has no host".into()))?;
            let port = request.uri().port_u16().unwrap_or(443);
            let stream =
                connect_tcp_for_websocket(host, port, configured_edge_proxy(host)?).await?;
            let (socket, _) =
                client_async_tls_with_config(request, stream, None, Some(tls_connector))
                    .await
                    .map_err(map_websocket_error)?;
            Ok(socket)
        })
    }
}

pub(super) fn configured_edge_proxy(host: &str) -> Result<Option<Url>, EdgeError> {
    let no_proxy = std::env::var("NO_PROXY")
        .or_else(|_| std::env::var("no_proxy"))
        .unwrap_or_default();
    if proxy_bypass_matches(host, &no_proxy) {
        return Ok(None);
    }

    let configured = [
        "EDGE_PROXY",
        "HTTPS_PROXY",
        "https_proxy",
        "ALL_PROXY",
        "all_proxy",
    ]
    .iter()
    .find_map(|name| {
        std::env::var(name)
            .ok()
            .filter(|value| !value.trim().is_empty())
    });
    let Some(configured) = configured else {
        return Ok(None);
    };
    let proxy = Url::parse(&configured)
        .map_err(|_| EdgeError::Transport("invalid Edge proxy URL".into()))?;
    if proxy.scheme() != "http"
        || proxy.host_str().is_none()
        || proxy.username() != ""
        || proxy.password().is_some()
    {
        return Err(EdgeError::Transport(
            "Edge proxy must be an unauthenticated http:// URL".into(),
        ));
    }
    Ok(Some(proxy))
}

pub(super) fn proxy_bypass_matches(host: &str, entries: &str) -> bool {
    entries.split(',').map(str::trim).any(|entry| {
        if entry.is_empty() {
            return false;
        }
        if entry == "*" {
            return true;
        }
        let domain = entry.trim_start_matches('.');
        host.eq_ignore_ascii_case(domain)
            || host
                .to_ascii_lowercase()
                .ends_with(&format!(".{}", domain.to_ascii_lowercase()))
    })
}

pub(super) async fn connect_tcp_for_websocket(
    host: &str,
    port: u16,
    proxy: Option<Url>,
) -> Result<TcpStream, EdgeError> {
    let Some(proxy) = proxy else {
        return TcpStream::connect((host, port))
            .await
            .map_err(|error| EdgeError::Transport(error.to_string()));
    };
    if proxy.path() != "/" || proxy.query().is_some() || proxy.fragment().is_some() {
        return Err(EdgeError::Transport(
            "Edge proxy URL cannot contain a path, query, or fragment".into(),
        ));
    }
    let proxy_host = proxy
        .host_str()
        .ok_or_else(|| EdgeError::Transport("Edge proxy URL has no host".into()))?;
    let proxy_port = proxy.port().unwrap_or(80);
    let mut stream = TcpStream::connect((proxy_host, proxy_port))
        .await
        .map_err(|error| EdgeError::Transport(format!("Edge proxy connection failed: {error}")))?;
    let authority_host = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_owned()
    };
    let authority = format!("{authority_host}:{port}");
    let connect_request = format!(
        "CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\nProxy-Connection: Keep-Alive\r\n\r\n"
    );
    stream
        .write_all(connect_request.as_bytes())
        .await
        .map_err(|error| EdgeError::Transport(format!("Edge proxy CONNECT failed: {error}")))?;
    let mut response = Vec::with_capacity(256);
    while response.len() < 16 * 1024 && !response.ends_with(b"\r\n\r\n") {
        let mut byte = [0u8; 1];
        stream
            .read_exact(&mut byte)
            .await
            .map_err(|error| EdgeError::Transport(format!("Edge proxy CONNECT failed: {error}")))?;
        response.push(byte[0]);
    }
    if !response.ends_with(b"\r\n\r\n") {
        return Err(EdgeError::Transport(
            "Edge proxy returned oversized CONNECT headers".into(),
        ));
    }
    let status = std::str::from_utf8(&response)
        .ok()
        .and_then(|headers| headers.lines().next())
        .and_then(|line| line.split_ascii_whitespace().nth(1))
        .and_then(|status| status.parse::<u16>().ok());
    if status != Some(200) {
        return Err(EdgeError::Transport(format!(
            "Edge proxy CONNECT returned HTTP {}",
            status.map_or_else(|| "invalid response".into(), |status| status.to_string())
        )));
    }
    Ok(stream)
}

pub(super) fn websocket_upgrade_request(request: Request<()>) -> Result<Request<()>, EdgeError> {
    let mut websocket_request = request
        .uri()
        .to_string()
        .into_client_request()
        .map_err(|error| EdgeError::Transport(error.to_string()))?;
    for (name, value) in request.headers() {
        websocket_request
            .headers_mut()
            .insert(name.clone(), value.clone());
    }
    Ok(websocket_request)
}

pub(super) fn map_websocket_error(error: tokio_tungstenite::tungstenite::Error) -> EdgeError {
    use tokio_tungstenite::tungstenite::Error as WebSocketError;

    match error {
        WebSocketError::Http(response) if response.status().as_u16() == 403 => {
            let edge_reference = response
                .headers()
                .get("x-msedge-ref")
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            let server_date = response
                .headers()
                .get(http::header::DATE)
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned);
            EdgeError::Forbidden {
                edge_reference,
                server_date,
            }
        }
        WebSocketError::Http(response) if matches!(response.status().as_u16(), 429 | 503) => {
            let retry_after = response
                .headers()
                .get("retry-after")
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.parse::<u64>().ok())
                .map(Duration::from_secs);
            EdgeError::RateLimited {
                status: response.status().as_u16(),
                retry_after,
            }
        }
        other => EdgeError::Transport(other.to_string()),
    }
}
