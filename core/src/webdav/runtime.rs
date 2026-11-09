//! WebDAV 策略的内置网络与本地仓库运行时实现。

use quick_xml::events::Event;
use quick_xml::name::ResolveResult;
use quick_xml::{NsReader, Reader};
use reqwest::Client;
use reqwest::{Method, StatusCode, Url};

use crate::{RemoteFileVersion, SyncProgressReporter};

use super::{
    WebDavEndpoint, WebDavError, WebDavPutCondition, WebDavRemoteFile, WebDavSyncEvent,
    WebDavSyncMonitor,
};

pub(crate) async fn test_connection(
    client: &Client,
    username: &str,
    password: &str,
    endpoint: &WebDavEndpoint,
) -> Result<(), WebDavError> {
    let url = Url::parse(&endpoint.base_url)
        .map_err(|_| WebDavError::Protocol("WebDAV 地址格式无效".into()))?;
    let response = request(
        client, username, password,
        Method::from_bytes(b"PROPFIND").expect("PROPFIND 应是有效方法"), url,
    )
    .header("Depth", "0")
    .header("Content-Type", "application/xml; charset=utf-8")
    .body("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>")
    .timeout(std::time::Duration::from_secs(15))
    .send().await.map_err(request_error)?;
    if response.status() != StatusCode::MULTI_STATUS {
        return Err(status_error(response.status()));
    }
    let target = response.url().clone();
    let body = response.text().await.map_err(request_error)?;
    validate_collection(&target, &body)
}

// Depth: 0 的响应必须明确确认目标本身是可访问的 DAV collection。
fn validate_collection(target: &Url, source: &str) -> Result<(), WebDavError> {
    let invalid = || WebDavError::Protocol("WebDAV 未返回可访问的目录".into());
    let mut reader = NsReader::from_str(source);
    reader.config_mut().trim_text(true);
    let mut stack: Vec<Vec<u8>> = Vec::new();
    let mut root_seen = false;
    let mut root_closed = false;
    let mut href = String::new();
    let mut response_status = None;
    let mut prop_status = None;
    let mut collection = false;
    let mut accessible_collection = false;
    let mut property_failure = None;
    let mut found = false;
    loop {
        match reader.read_event().map_err(|_| invalid())? {
            event @ (Event::Start(_) | Event::Empty(_)) => {
                let empty = matches!(event, Event::Empty(_));
                let event = match event {
                    Event::Start(event) | Event::Empty(event) => event,
                    _ => unreachable!(),
                };
                let (namespace, local) = reader.resolve_element(event.name());
                let name = if matches!(namespace, ResolveResult::Bound(ref ns) if ns.as_ref() == b"DAV:")
                {
                    local.as_ref().to_vec()
                } else {
                    Vec::new()
                };
                if stack.is_empty() {
                    if root_seen || name != b"multistatus" || empty {
                        return Err(invalid());
                    }
                    root_seen = true;
                }
                if stack.len() == 1 && name == b"response" {
                    href.clear();
                    response_status = None;
                    accessible_collection = false;
                    property_failure = None;
                }
                if stack.len() == 2 && name == b"propstat" {
                    prop_status = None;
                    collection = false;
                }
                if stack.len() == 5
                    && stack[1] == b"response"
                    && stack[2] == b"propstat"
                    && stack[3] == b"prop"
                    && stack[4] == b"resourcetype"
                    && name == b"collection"
                {
                    collection = true;
                }
                if !empty {
                    stack.push(name);
                }
            }
            Event::Text(text) => {
                let value = text.unescape().map_err(|_| invalid())?;
                if stack.is_empty() && !value.trim().is_empty() {
                    return Err(invalid());
                }
                if stack.len() == 3 && stack[1] == b"response" && stack[2] == b"href" {
                    href.push_str(&value);
                }
                let status = value
                    .split_whitespace()
                    .nth(1)
                    .and_then(|code| code.parse::<u16>().ok());
                if stack.len() == 3 && stack[1] == b"response" && stack[2] == b"status" {
                    response_status = status;
                }
                if stack.len() == 4
                    && stack[1] == b"response"
                    && stack[2] == b"propstat"
                    && stack[3] == b"status"
                {
                    prop_status = status;
                }
            }
            Event::End(_) => {
                if stack.len() == 3 && stack[1] == b"response" && stack[2] == b"propstat" {
                    accessible_collection |=
                        collection && prop_status.is_some_and(|code| (200..300).contains(&code));
                    if prop_status.is_some_and(|code| !(200..300).contains(&code)) {
                        property_failure = prop_status;
                    }
                }
                if stack.len() == 2 && stack[1] == b"response" {
                    let matches_target = target.join(&href).is_ok_and(|url| {
                        !href.is_empty()
                            && url.origin() == target.origin()
                            && url.path().trim_end_matches('/')
                                == target.path().trim_end_matches('/')
                    });
                    if matches_target {
                        if response_status.is_some_and(|code| !(200..300).contains(&code)) {
                            return Err(status_error(
                                StatusCode::from_u16(response_status.unwrap())
                                    .map_err(|_| invalid())?,
                            ));
                        }
                        if !accessible_collection && let Some(code) = property_failure {
                            return Err(status_error(
                                StatusCode::from_u16(code).map_err(|_| invalid())?,
                            ));
                        }
                        found |= accessible_collection;
                    }
                }
                if stack.pop().is_none() {
                    return Err(invalid());
                }
                if stack.is_empty() {
                    root_closed = true;
                }
            }
            Event::Eof => break,
            Event::DocType(_) => return Err(invalid()),
            _ => {}
        }
    }
    if root_seen && root_closed && stack.is_empty() && found {
        Ok(())
    } else {
        Err(invalid())
    }
}

pub(crate) async fn list_remote_tree(
    client: &Client,
    username: &str,
    password: &str,
    endpoint: &WebDavEndpoint,
    options: &crate::SyncOptions,
    progress: &SyncProgressReporter,
    monitor: &dyn WebDavSyncMonitor,
) -> Result<Vec<WebDavRemoteFile>, WebDavError> {
    let mut queue = std::collections::VecDeque::from([String::new()]);
    let mut visited = std::collections::BTreeSet::new();
    let mut result = Vec::new();
    while let Some(prefix) = queue.pop_front() {
        if !visited.insert(prefix.clone()) {
            continue;
        }
        let directory = WebDavEndpoint {
            base_url: format!("{}/{}", endpoint.base_url.trim_end_matches('/'), prefix),
        };
        let (files, children) =
            list_remote_level(client, username, password, &directory, progress, monitor).await?;
        for mut file in files {
            file.path = format!("{prefix}{}", file.path);
            if !options.excludes_path(&file.path) {
                result.push(file);
            }
        }
        for child in children {
            let path = format!("{prefix}{}", child.trim_end_matches('/'));
            if path.split('/').any(|part| part == ".sync")
                || options.excludes_path(&format!("{path}/file.org"))
            {
                continue;
            }
            if visited.len() + queue.len() > 10000 {
                return Err(WebDavError::Protocol("远端目录数量超过允许上限".into()));
            }
            queue.push_back(format!("{path}/"));
        }
    }
    Ok(result)
}

// 只有合法且完整的 multistatus 才证明相应目录范围已列举；失败响应不能伪装成删除。
fn collection_paths(endpoint: &str, source: &str) -> Result<Vec<String>, WebDavError> {
    let invalid = || WebDavError::Protocol("WebDAV 目录列举响应不完整或包含失败状态".into());
    let base = Url::parse(endpoint).map_err(|_| invalid())?;
    let mut reader = NsReader::from_str(source);
    reader.config_mut().trim_text(true);
    let mut stack = Vec::<Vec<u8>>::new();
    let (mut opened, mut closed) = (false, false);
    let (mut href, mut collection) = (String::new(), false);
    let mut directories = Vec::new();
    loop {
        match reader.read_event().map_err(|_| invalid())? {
            event @ (Event::Start(_) | Event::Empty(_)) => {
                let empty = matches!(event, Event::Empty(_));
                let raw = match event {
                    Event::Start(e) | Event::Empty(e) => e,
                    _ => unreachable!(),
                };
                let (ns, name) = reader.resolve_element(raw.name());
                let name = if matches!(ns,ResolveResult::Bound(ref ns) if ns.as_ref()==b"DAV:") {
                    name.as_ref().to_vec()
                } else {
                    Vec::new()
                };
                if stack.is_empty() {
                    if opened || closed || name != b"multistatus" {
                        return Err(invalid());
                    }
                    opened = true;
                    if empty {
                        closed = true;
                    }
                }
                if name == b"response" {
                    href.clear();
                    collection = false;
                }
                if name == b"collection" {
                    collection = true;
                }
                if !empty {
                    stack.push(name);
                }
            }
            Event::Text(text) => {
                let text = text.unescape().map_err(|_| invalid())?;
                match stack.last().map(Vec::as_slice) {
                    Some(b"href") => href.push_str(&text),
                    Some(b"status") => {
                        let status = text
                            .split_whitespace()
                            .nth(1)
                            .and_then(|s| s.parse::<u16>().ok())
                            .ok_or_else(invalid)?;
                        if !(200..300).contains(&status) {
                            return Err(status_error(
                                StatusCode::from_u16(status).map_err(|_| invalid())?,
                            ));
                        }
                    }
                    None if !text.trim().is_empty() => return Err(invalid()),
                    _ => {}
                }
            }
            Event::End(event) => {
                let (ns, name) = reader.resolve_element(event.name());
                let name = if matches!(ns,ResolveResult::Bound(ref ns) if ns.as_ref()==b"DAV:") {
                    name.as_ref().to_vec()
                } else {
                    Vec::new()
                };
                let Some(last) = stack.pop() else {
                    return Err(invalid());
                };
                if last != name {
                    return Err(invalid());
                }
                if last == b"response" && collection {
                    if let Some(path) = relative_path(&base, &href) {
                        directories.push(format!("{}/", path.trim_end_matches('/')));
                    }
                }
                if stack.is_empty() {
                    closed = true;
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if !opened || !closed || !stack.is_empty() {
        return Err(invalid());
    }
    Ok(directories)
}

async fn list_remote_level(
    client: &Client,
    username: &str,
    password: &str,
    endpoint: &WebDavEndpoint,
    progress: &SyncProgressReporter,
    monitor: &dyn WebDavSyncMonitor,
) -> Result<(Vec<WebDavRemoteFile>, Vec<String>), WebDavError> {
    let url = Url::parse(&endpoint.base_url)
        .map_err(|_| WebDavError::Protocol("WebDAV 地址格式无效".into()))?;
    progress.report_http("PROPFIND / -> 请求中");
    monitor.on_event(WebDavSyncEvent::HttpRequest {
        method: "PROPFIND".into(),
        path: "/".into(),
    });
    let response = request(
        client,
        username,
        password,
        Method::from_bytes(b"PROPFIND").expect("PROPFIND 应是有效方法"),
        url,
    )
    .header("Depth", "1")
    .send()
    .await
    .map_err(|error| {
        progress.report_http("PROPFIND / -> 请求失败");
        monitor.on_event(WebDavSyncEvent::HttpResponse {
            method: "PROPFIND".into(),
            path: "/".into(),
            status: None,
        });
        request_error(error)
    })?;
    progress.report_http(format!("PROPFIND / -> {}", response.status().as_u16()));
    monitor.on_event(WebDavSyncEvent::HttpResponse {
        method: "PROPFIND".into(),
        path: "/".into(),
        status: Some(response.status().as_u16()),
    });
    if response.status() != StatusCode::MULTI_STATUS {
        return Err(status_error(response.status()));
    }
    let body = response
        .text()
        .await
        .map_err(|_| WebDavError::Protocol("无法读取 WebDAV 列举响应".into()))?;
    let directories = collection_paths(&endpoint.base_url, &body)?;
    let mut files = parse_multistatus(&endpoint.base_url, &body)?;
    files.retain(|file| {
        !directories
            .iter()
            .any(|dir| dir.trim_end_matches('/') == file.path)
    });
    Ok((files, directories))
}

pub(crate) async fn get_remote(
    client: &Client,
    username: &str,
    password: &str,
    endpoint: &WebDavEndpoint,
    path: &str,
    expected_etag: Option<&str>,
    progress: &SyncProgressReporter,
    monitor: &dyn WebDavSyncMonitor,
) -> Result<Vec<u8>, WebDavError> {
    progress.report_http(format!("GET {path} -> 请求中"));
    monitor.on_event(WebDavSyncEvent::HttpRequest {
        method: "GET".into(),
        path: path.into(),
    });
    let mut download = request(
        client,
        username,
        password,
        Method::GET,
        file_url(endpoint, path)?,
    );
    if let Some(etag) = expected_etag.filter(|etag| !etag.starts_with("W/")) {
        download = download.header("If-Match", etag);
    }
    let response = download
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await
        .map_err(|error| {
            progress.report_http(format!("GET {path} -> 请求失败"));
            monitor.on_event(WebDavSyncEvent::HttpResponse {
                method: "GET".into(),
                path: path.into(),
                status: None,
            });
            request_error(error)
        })?;
    progress.report_http(format!("GET {path} -> {}", response.status().as_u16()));
    monitor.on_event(WebDavSyncEvent::HttpResponse {
        method: "GET".into(),
        path: path.into(),
        status: Some(response.status().as_u16()),
    });
    if response.status() != StatusCode::OK {
        return Err(status_error(response.status()));
    }
    if expected_etag.is_some_and(|expected| {
        response
            .headers()
            .get("ETag")
            .and_then(|value| value.to_str().ok())
            .is_some_and(|actual| actual != expected)
    }) {
        return Err(WebDavError::Conflict("远端已改变，请重新同步".into()));
    }
    response
        .bytes()
        .await
        .map(|bytes| bytes.to_vec())
        .map_err(|_| WebDavError::Protocol("无法读取 WebDAV 文件内容".into()))
}

pub(crate) async fn delete_remote(
    client: &Client,
    username: &str,
    password: &str,
    endpoint: &WebDavEndpoint,
    path: &str,
    etag: &str,
    progress: &SyncProgressReporter,
    monitor: &dyn WebDavSyncMonitor,
) -> Result<(), WebDavError> {
    progress.report_http(format!("DELETE {path} -> 请求中"));
    monitor.on_event(WebDavSyncEvent::HttpRequest {
        method: "DELETE".into(),
        path: path.into(),
    });
    let response = request(
        client,
        username,
        password,
        Method::DELETE,
        file_url(endpoint, path)?,
    )
    .header("If-Match", etag)
    .timeout(std::time::Duration::from_secs(30))
    .send()
    .await
    .map_err(|error| {
        monitor.on_event(WebDavSyncEvent::HttpResponse {
            method: "DELETE".into(),
            path: path.into(),
            status: None,
        });
        request_error(error)
    })?;
    let status = response.status();
    progress.report_http(format!("DELETE {path} -> {}", status.as_u16()));
    monitor.on_event(WebDavSyncEvent::HttpResponse {
        method: "DELETE".into(),
        path: path.into(),
        status: Some(status.as_u16()),
    });
    if matches!(
        status,
        StatusCode::OK | StatusCode::NO_CONTENT | StatusCode::NOT_FOUND
    ) {
        Ok(())
    } else {
        Err(status_error(status))
    }
}

pub(crate) async fn put_remote(
    client: &Client,
    username: &str,
    password: &str,
    endpoint: &WebDavEndpoint,
    path: &str,
    source_bytes: &[u8],
    condition: WebDavPutCondition,
    progress: &SyncProgressReporter,
    monitor: &dyn WebDavSyncMonitor,
) -> Result<RemoteFileVersion, WebDavError> {
    progress.report_http(format!("PUT {path} -> 请求中"));
    monitor.on_event(WebDavSyncEvent::HttpRequest {
        method: "PUT".into(),
        path: path.into(),
    });
    let mut request = request(
        client,
        username,
        password,
        Method::PUT,
        file_url(endpoint, path)?,
    )
    .header("Content-Type", "text/plain; charset=utf-8")
    .body(source_bytes.to_vec());
    request = match condition {
        WebDavPutCondition::CreateOnly => request.header("If-None-Match", "*"),
        WebDavPutCondition::Match(etag) => request.header("If-Match", etag),
    };
    let response = request
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await
        .map_err(|error| {
            progress.report_http(format!("PUT {path} -> 请求失败"));
            monitor.on_event(WebDavSyncEvent::HttpResponse {
                method: "PUT".into(),
                path: path.into(),
                status: None,
            });
            request_error(error)
        })?;
    progress.report_http(format!("PUT {path} -> {}", response.status().as_u16()));
    monitor.on_event(WebDavSyncEvent::HttpResponse {
        method: "PUT".into(),
        path: path.into(),
        status: Some(response.status().as_u16()),
    });
    if !matches!(
        response.status(),
        StatusCode::OK | StatusCode::CREATED | StatusCode::NO_CONTENT
    ) {
        return Err(status_error(response.status()));
    }
    let etag = response
        .headers()
        .get("etag")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    RemoteFileVersion::new(etag, None, Some(source_bytes.len() as i64))
        .map_err(|_| WebDavError::Protocol("远端版本信息无效".into()))
}

fn request(
    client: &Client,
    username: &str,
    password: &str,
    method: Method,
    url: Url,
) -> reqwest::RequestBuilder {
    client
        .request(method, url)
        .basic_auth(username, Some(password))
}

fn parse_multistatus(base_url: &str, source: &str) -> Result<Vec<WebDavRemoteFile>, WebDavError> {
    let base =
        Url::parse(base_url).map_err(|_| WebDavError::Protocol("WebDAV 地址格式无效".into()))?;
    let mut reader = Reader::from_str(source);
    reader.config_mut().trim_text(true);
    let mut in_response = false;
    let mut field: Option<Vec<u8>> = None;
    let mut href = None;
    let mut etag = None;
    let mut size = None;
    let mut files = Vec::new();
    loop {
        match reader
            .read_event()
            .map_err(|_| WebDavError::Protocol("WebDAV 列举 XML 无效".into()))?
        {
            Event::Start(event) if tag(event.name().as_ref(), b"response") => {
                in_response = true;
                href = None;
                etag = None;
                size = None;
            }
            Event::Start(event) if in_response => field = Some(event.name().as_ref().to_vec()),
            Event::Text(text) if in_response => {
                let value = text
                    .unescape()
                    .map_err(|_| WebDavError::Protocol("WebDAV 列举 XML 无效".into()))?
                    .trim()
                    .to_owned();
                match field.as_deref() {
                    Some(name) if tag(name, b"href") => href = Some(value),
                    Some(name) if tag(name, b"getetag") => etag = Some(value),
                    Some(name) if tag(name, b"getcontentlength") => size = value.parse().ok(),
                    _ => {}
                }
            }
            Event::End(event) if tag(event.name().as_ref(), b"response") => {
                if let Some(path) = href
                    .as_deref()
                    .and_then(|value| relative_path(&base, value))
                {
                    if (path.ends_with(".org") || path == crate::model::TASK_SCAN_RULES_PATH)
                        && !path.starts_with(".sync/")
                        && path != ".sync"
                    {
                        let version = RemoteFileVersion::new(etag.clone(), None, size)
                            .map_err(|_| WebDavError::Protocol("WebDAV 文件版本无效".into()))?;
                        files
                            .push(WebDavRemoteFile::new(path, version).map_err(|_| {
                                WebDavError::Protocol("WebDAV 文件路径无效".into())
                            })?);
                    }
                }
                in_response = false;
                field = None;
            }
            Event::End(_) => field = None,
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(files)
}

fn relative_path(base: &Url, href: &str) -> Option<String> {
    let target = Url::parse(href).or_else(|_| base.join(href)).ok()?;
    if target.scheme() != base.scheme()
        || target.host_str() != base.host_str()
        || target.port_or_known_default() != base.port_or_known_default()
    {
        return None;
    }
    let base_path = base.path().trim_end_matches('/');
    let target_path = target.path();
    let relative = target_path.strip_prefix(&format!("{base_path}/"))?;
    if relative.is_empty() || relative.contains("..") {
        return None;
    }
    Some(relative.into())
}

fn file_url(endpoint: &WebDavEndpoint, path: &str) -> Result<Url, WebDavError> {
    if path.is_empty()
        || path.starts_with('/')
        || path
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err(WebDavError::Protocol("WebDAV 文件路径无效".into()));
    }
    let mut base = endpoint.base_url.clone();
    if !base.ends_with('/') {
        base.push('/');
    }
    Url::parse(&base)
        .and_then(|url| url.join(path))
        .map_err(|_| WebDavError::Protocol("WebDAV 文件地址无效".into()))
}

fn tag(name: &[u8], expected: &[u8]) -> bool {
    name.rsplit(|value| *value == b':').next() == Some(expected)
}

fn request_error(error: reqwest::Error) -> WebDavError {
    if error.is_connect() || error.is_timeout() {
        WebDavError::Network("WebDAV 网络请求失败".into())
    } else {
        WebDavError::Protocol("WebDAV 请求失败".into())
    }
}

fn status_error(status: StatusCode) -> WebDavError {
    match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
            WebDavError::Authentication("WebDAV 认证失败".into())
        }
        StatusCode::PRECONDITION_FAILED => WebDavError::Conflict("WebDAV 条件写入冲突".into()),
        _ => WebDavError::Protocol(format!("WebDAV 返回 HTTP {}", status.as_u16())),
    }
}

#[cfg(test)]
mod connection_tests {
    use super::*;
    use crate::webdav::WebDavSyncPolicy;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn collection(href: &str, status: u16) -> String {
        format!(
            "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>{href}</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 {status} Result</d:status></d:propstat></d:response></d:multistatus>"
        )
    }

    #[test]
    fn validates_directory_identity_namespace_and_property_status() {
        let target = Url::parse("https://dav.example.com/org/").unwrap();
        assert!(validate_collection(&target, &collection("/org/", 200)).is_ok());
        assert!(
            validate_collection(&target, &collection("https://dav.example.com/org/", 200)).is_ok()
        );
        assert!(
            validate_collection(
                &target,
                &collection("/org/", 200)
                    .replace("<d:collection/>", "<d:collection></d:collection>")
            )
            .is_ok()
        );
        for source in [
            String::new(),
            "<html>login</html>".into(),
            "<d:multistatus xmlns:d=\"DAV:\"/>".into(),
            collection("/org/", 200).replace("DAV:", "wrong:"),
            collection("/org/child/", 200),
            collection("https://other.example.com/org/", 200),
            collection("/org/", 200).replace("<d:collection/>", ""),
            collection("/org/", 200).replace("</d:multistatus>", ""),
            format!("{}<extra/>", collection("/org/", 200)),
            collection("/org/", 404),
        ] {
            assert!(
                matches!(
                    validate_collection(&target, &source),
                    Err(WebDavError::Protocol(_))
                ),
                "{source}"
            );
        }
        assert!(matches!(
            validate_collection(&target, &collection("/org/", 403)),
            Err(WebDavError::Authentication(_))
        ));
        let default_ns = collection("/org/", 200)
            .replace("d:", "")
            .replace("xmlns:d", "xmlns");
        assert!(validate_collection(&target, &default_ns).is_ok());
    }

    async fn serve(
        status: u16,
        body: String,
        delay_body: bool,
    ) -> (WebDavSyncPolicy, tokio::task::JoinHandle<String>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint =
            WebDavEndpoint::new(format!("http://{}/org/", listener.local_addr().unwrap())).unwrap();
        let worker = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut buffer = [0; 4096];
            let header_end;
            loop {
                let count = stream.read(&mut buffer).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&buffer[..count]);
                if let Some(offset) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                    header_end = offset + 4;
                    break;
                }
            }
            let headers = String::from_utf8(request[..header_end].to_vec()).unwrap();
            let length = headers
                .lines()
                .find_map(|line| {
                    line.to_lowercase()
                        .strip_prefix("content-length: ")?
                        .parse::<usize>()
                        .ok()
                })
                .unwrap();
            while request.len() < header_end + length {
                let count = stream.read(&mut buffer).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&buffer[..count]);
            }
            let response = format!(
                "HTTP/1.1 {status} Result\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream.write_all(response.as_bytes()).await.unwrap();
            if delay_body {
                std::future::pending::<()>().await;
            }
            stream.write_all(body.as_bytes()).await.unwrap();
            String::from_utf8(request).unwrap()
        });
        (
            WebDavSyncPolicy::new(endpoint, "user".into(), "password".into()).unwrap(),
            worker,
        )
    }

    #[tokio::test]
    async fn probe_authenticates_and_only_reads_target_collection() {
        let (policy, worker) = serve(207, collection("/org/", 200), false).await;
        policy.test_connection().await.unwrap();
        let request = worker.await.unwrap();
        assert!(request.starts_with("PROPFIND /org/ HTTP/1.1\r\n"));
        let headers = request.to_lowercase();
        assert!(headers.contains("depth: 0\r\n"));
        assert!(headers.contains("authorization: basic dxnlcjpwyxnzd29yza==\r\n"));
        assert!(request.contains("<d:resourcetype/>"));
        assert!(!request.contains("PUT "));
        assert!(!request.contains("GET "));
    }

    #[tokio::test]
    async fn probe_rejects_authentication_missing_directory_and_non_dav_responses() {
        for status in [401, 403, 404, 500, 200, 207] {
            let (policy, worker) = serve(status, "<html>login</html>".into(), false).await;
            let error = policy.test_connection().await.unwrap_err();
            if matches!(status, 401 | 403) {
                assert!(matches!(error, WebDavError::Authentication(_)));
            } else {
                assert!(matches!(error, WebDavError::Protocol(_)));
            }
            assert!(!format!("{error:?}").contains("password"));
            assert!(!format!("{error:?}").contains("127.0.0.1"));
            worker.await.unwrap();
        }
    }

    #[tokio::test]
    async fn probe_times_out_even_after_response_headers_arrive() {
        let (policy, worker) = serve(207, collection("/org/", 200), true).await;
        let result =
            tokio::time::timeout(std::time::Duration::from_secs(17), policy.test_connection())
                .await
                .unwrap();
        assert!(matches!(result, Err(WebDavError::Network(_))));
        worker.abort();
    }
}

#[cfg(test)]
mod snapshot_listing_tests {
    use super::*;
    #[test]
    fn incomplete_failed_or_wrong_origin_listing_is_not_a_complete_snapshot() {
        let base = "https://dav.example.com/org/";
        let xml = "<d:multistatus xmlns:d=\"DAV:\" xmlns:x=\"http://example.com/custom\"><d:response><d:href>/org/nested/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><x:custom>extra</x:custom></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>";
        assert_eq!(collection_paths(base, xml).unwrap(), vec!["nested/"]);
        assert!(collection_paths(base, &xml.replace("</d:multistatus>", "")).is_err());
        assert!(collection_paths(base, &xml.replace("200 OK", "403 Forbidden")).is_err());
        assert!(collection_paths(base, "<html/>").is_err());
        let url = Url::parse(base).unwrap();
        assert!(relative_path(&url, "https://dav.example.com:444/org/a.org").is_none());
        assert!(relative_path(&url, "https://dav.example.com/org-other/a.org").is_none());
    }
}
