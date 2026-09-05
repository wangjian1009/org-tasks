//! WebDAV 策略的内置网络与本地仓库运行时实现。

use std::path::{Path, PathBuf};

use quick_xml::Reader;
use quick_xml::events::Event;
use reqwest::Client;
use reqwest::{Method, StatusCode, Url};
use tokio::fs;

use crate::{CoreError, OrgRepo, RemoteFileVersion, SyncProgressReporter};

use super::{
    WebDavEndpoint, WebDavError, WebDavPutCondition, WebDavRemoteFile, WebDavSyncEvent,
    WebDavSyncMonitor,
};

pub(crate) async fn list_remote(
    client: &Client,
    username: &str,
    password: &str,
    endpoint: &WebDavEndpoint,
    progress: &SyncProgressReporter,
    monitor: &dyn WebDavSyncMonitor,
) -> Result<Vec<WebDavRemoteFile>, WebDavError> {
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
    parse_multistatus(&endpoint.base_url, &body)
}

pub(crate) async fn get_remote(
    client: &Client,
    username: &str,
    password: &str,
    endpoint: &WebDavEndpoint,
    path: &str,
    progress: &SyncProgressReporter,
    monitor: &dyn WebDavSyncMonitor,
) -> Result<Vec<u8>, WebDavError> {
    progress.report_http(format!("GET {path} -> 请求中"));
    monitor.on_event(WebDavSyncEvent::HttpRequest {
        method: "GET".into(),
        path: path.into(),
    });
    let response = request(
        client,
        username,
        password,
        Method::GET,
        file_url(endpoint, path)?,
    )
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
    response
        .bytes()
        .await
        .map(|bytes| bytes.to_vec())
        .map_err(|_| WebDavError::Protocol("无法读取 WebDAV 文件内容".into()))
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
    let response = request.send().await.map_err(|error| {
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

/// 将一个下载文件写入本地仓库。
pub(crate) async fn write_downloaded_file(
    repo: &OrgRepo,
    path: &str,
    source_bytes: &[u8],
) -> Result<(), CoreError> {
    let target =
        safe_local_path(Path::new(&repo.root_directory), path).map_err(CoreError::Store)?;
    let parent = target
        .parent()
        .ok_or(CoreError::InvalidState("下载文件缺少父目录"))?;
    fs::create_dir_all(parent)
        .await
        .map_err(|error| CoreError::Store(format!("无法创建下载目录: {error}")))?;
    fs::write(target, source_bytes)
        .await
        .map_err(|error| CoreError::Store(format!("无法写入下载文件: {error}")))?;
    Ok(())
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
                let value = String::from_utf8_lossy(text.as_ref()).trim().to_owned();
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
                    if path.ends_with(".org") && !path.starts_with(".sync/") && path != ".sync" {
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
    if target.scheme() != base.scheme() || target.host_str() != base.host_str() {
        return None;
    }
    let base_path = base.path().trim_end_matches('/');
    let target_path = target.path();
    let relative = target_path.strip_prefix(base_path)?.trim_start_matches('/');
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

fn safe_local_path(root: &Path, relative: &str) -> Result<PathBuf, String> {
    if relative.is_empty()
        || relative.starts_with('/')
        || relative
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == ".." || part == ".sync")
    {
        return Err("下载文件路径无效".into());
    }
    Ok(root.join(relative))
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
