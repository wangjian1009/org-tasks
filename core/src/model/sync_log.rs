//! 日志存储与宽容读取；运行中同步和恢复状态仍使用严格类型。
use super::{OrgRepoSyncRecord, SyncContextDetail, SyncFileDetail};
use crate::webdav::transaction::{self, Plan};
use crate::{CoreError, TimestampMs};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Map, Value};
use std::collections::BTreeSet;
use std::path::Path;
use tokio::fs;
use tokio::io::{AsyncBufReadExt, BufReader};

const ROOT: &str = ".sync/history";
const MAX_LINE: usize = 16 * 1024;
const MAX_SUMMARY: usize = 256 * 1024;

/// 历史字段逐项解码；None 不表示成功、零数量或有效的空路径。
#[derive(Clone, Debug, Default, Serialize)]
pub struct SyncLogData {
    pub id: Option<String>,
    pub kind: Option<String>,
    pub started_at: Option<TimestampMs>,
    pub finished_at: Option<TimestampMs>,
    pub result: Option<String>,
    pub execution_result: Option<String>,
    pub file_count: Option<usize>,
    pub downloaded_count: Option<usize>,
    pub uploaded_count: Option<usize>,
    pub conflict_count: Option<usize>,
    pub conflicts: Option<Vec<String>>,
    pub trigger_reason: Option<String>,
    pub event: Option<String>,
    pub relative_path: Option<String>,
    pub action: Option<String>,
    pub state: Option<String>,
    pub outcome: Option<String>,
    pub local_version: Option<super::LocalFileVersion>,
    pub detail: Option<Value>,
    pub error: Option<Value>,
    pub context_detail: Option<Value>,
    pub source_hash: Option<String>,
}
#[derive(Clone, Debug, Serialize)]
pub struct SyncLogIssue {
    pub path: String,
    pub field: Option<String>,
    pub message: String,
}
#[derive(Clone, Debug)]
pub struct SyncLogRecord {
    /// 可验证的存储定位符，独立于可能缺失的历史字段。
    pub key: String,
    pub data: SyncLogData,
    pub issues: Vec<SyncLogIssue>,
    pub(crate) time: TimestampMs,
    pub(crate) legacy: Option<Value>,
}
#[derive(Clone, Debug)]
pub struct SyncLogDetail {
    pub summary: SyncLogRecord,
    pub files: Vec<SyncLogRecord>,
}

fn io(error: std::io::Error) -> CoreError {
    CoreError::Store(format!("无法读写同步日志: {error}"))
}
fn issue(path: &str, field: Option<&str>, message: &str) -> SyncLogIssue {
    SyncLogIssue {
        path: path.into(),
        field: field.map(str::to_owned),
        message: message.into(),
    }
}
fn field<T: DeserializeOwned>(
    object: &Map<String, Value>,
    key: &str,
    path: &str,
    issues: &mut Vec<SyncLogIssue>,
) -> Option<T> {
    let value = object.get(key).filter(|value| !value.is_null())?;
    match serde_json::from_value(value.clone()) {
        Ok(value) => Some(value),
        Err(_) => {
            issues.push(issue(path, Some(key), "字段类型无效"));
            None
        }
    }
}
impl SyncLogData {
    /// 历史结果由 Core 兼容旧动作／状态；缺少必要字段时不推断成功。
    pub fn file_outcome(&self) -> Option<&str> {
        if self.outcome.as_deref() == Some("conflict")
            || ((self.outcome.is_none() || self.outcome.as_deref() == Some("legacy"))
                && (matches!(self.state.as_deref(), Some("conflict" | "remoteDeleted"))
                    || self
                        .error
                        .as_ref()
                        .is_some_and(|error| error["category"] == "Conflict")))
        {
            return Some("conflict");
        }
        if self.state.as_deref() == Some("failed") {
            return Some("failed");
        }
        if let Some(outcome) = self.outcome.as_deref().filter(|value| *value != "legacy") {
            return Some(outcome);
        }
        self.state.as_ref()?;
        self.action.as_deref().map(|action| {
            if action == "conflicted" {
                "conflict"
            } else {
                action
            }
        })
    }
    pub fn from_json(value: &Value, path: &str) -> (Self, Vec<SyncLogIssue>) {
        let mut issues = Vec::new();
        let Some(object) = value.as_object() else {
            return (Self::default(), vec![issue(path, None, "日志不是对象")]);
        };
        macro_rules! get {
            ($name:ident) => {
                field(object, stringify!($name), path, &mut issues)
            };
        }
        let mut data = Self {
            id: get!(id),
            kind: get!(kind),
            started_at: get!(started_at),
            finished_at: get!(finished_at),
            result: get!(result),
            execution_result: get!(execution_result),
            file_count: get!(file_count),
            downloaded_count: get!(downloaded_count),
            uploaded_count: get!(uploaded_count),
            conflict_count: get!(conflict_count),
            conflicts: get!(conflicts),
            trigger_reason: get!(trigger_reason),
            event: get!(event),
            relative_path: get!(relative_path),
            action: get!(action),
            state: get!(state),
            outcome: get!(outcome),
            local_version: get!(local_version),
            detail: get!(detail),
            error: get!(error),
            context_detail: get!(context_detail),
            source_hash: get!(source_hash),
        };
        for (name, value, allowed) in [
            (
                "result",
                &mut data.result,
                &["succeeded", "failed", "cancelled", "interrupted"][..],
            ),
            (
                "execution_result",
                &mut data.execution_result,
                &["succeeded", "failed", "cancelled", "interrupted"][..],
            ),
            (
                "action",
                &mut data.action,
                &[
                    "unchanged",
                    "downloaded",
                    "uploaded",
                    "created",
                    "deleted",
                    "conflicted",
                    "skipped",
                ][..],
            ),
            (
                "state",
                &mut data.state,
                &[
                    "synchronized",
                    "localChanged",
                    "remoteChanged",
                    "remoteDeleted",
                    "conflict",
                    "failed",
                ][..],
            ),
            (
                "outcome",
                &mut data.outcome,
                &[
                    "legacy",
                    "unchanged",
                    "downloaded",
                    "uploaded",
                    "created",
                    "deleted",
                    "updated",
                    "merged",
                    "conflict",
                    "failed",
                    "skipped",
                ][..],
            ),
        ] {
            if let Some(raw) = value.as_ref() {
                let normalized = lower_first(raw);
                if allowed.contains(&normalized.as_str()) {
                    *value = Some(normalized);
                } else {
                    *value = None;
                    issues.push(issue(path, Some(name), "字段值不受支持"));
                }
            }
        }
        if data.relative_path.as_ref().is_some_and(|path| {
            super::validate_relative_path(path).is_err()
                || path.split('/').any(|part| part == ".sync")
        }) {
            data.relative_path = None;
            issues.push(issue(path, Some("relative_path"), "文件路径无效"));
        }
        if data.started_at.is_some_and(|value| value < 0) {
            data.started_at = None;
            issues.push(issue(path, Some("started_at"), "时间无效"));
        }
        if data
            .finished_at
            .is_some_and(|value| value < 0 || data.started_at.is_some_and(|start| value < start))
        {
            data.finished_at = None;
            issues.push(issue(path, Some("finished_at"), "结束时间无效"));
        }
        (data, issues)
    }
}
fn lower_first(value: &str) -> String {
    let mut chars = value.chars();
    match chars.next() {
        Some(first) => first.to_lowercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}
pub(crate) fn file_key(path: &str) -> String {
    ring::digest::digest(&ring::digest::SHA256, path.as_bytes())
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
pub(crate) fn file_root(time: TimestampMs, path: &str) -> String {
    format!("{ROOT}/{time}/files/{}", file_key(path))
}
fn filename(path: &str) -> Result<&str, CoreError> {
    path.rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
        .ok_or(CoreError::InvalidInput("日志文件名无效"))
}
fn escape(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}
fn unescape(value: &str) -> Option<String> {
    let mut result = String::new();
    let mut chars = value.chars();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            result.push(ch);
            continue;
        }
        result.push(match chars.next()? {
            '\\' => '\\',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            _ => return None,
        });
    }
    Some(result)
}
fn add_line(output: &mut String, key: &str, value: impl ToString) {
    output.push_str(key);
    output.push('=');
    output.push_str(&escape(&value.to_string()));
    output.push('\n');
}

/// 只枚举占用的时间戳，不读取任何旧历史正文。
pub(crate) async fn occupied_times(root: &Path) -> Result<BTreeSet<TimestampMs>, CoreError> {
    let path = safe_directory(root, ROOT).await?;
    let mut entries = match fs::read_dir(&path).await {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(BTreeSet::new()),
        Err(e) => return Err(io(e)),
    };
    let mut times = BTreeSet::new();
    while let Some(entry) = entries.next_entry().await.map_err(io)? {
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let stem = name.strip_suffix(".json").unwrap_or(name);
        if let Ok(time) = stem.parse::<TimestampMs>() {
            times.insert(time);
        }
    }
    Ok(times)
}

fn summary_fields(record: &Value) -> Map<String, Value> {
    let mut fields = record.as_object().cloned().unwrap_or_default();
    let files = fields
        .remove("files")
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default();
    let mut downloads = 0;
    let mut uploads = 0;
    let mut conflicts = Vec::new();
    let mut failed = false;
    let mut error_category = None;
    let mut error_message = None;
    let modern = record["context_detail"]["format_version"]
        .as_u64()
        .unwrap_or(0)
        >= 4;
    for file in &files {
        let state = lower_first(file["state"].as_str().unwrap_or(""));
        let action = lower_first(file["action"].as_str().unwrap_or(""));
        let outcome = file["outcome"].as_str().map(lower_first);
        let conflict = outcome.as_deref() == Some("conflict")
            || ((outcome.is_none() || outcome.as_deref() == Some("legacy"))
                && (state == "conflict"
                    || state == "remoteDeleted"
                    || file["error"]["category"] == "Conflict"));
        if conflict && let Some(path) = file["relative_path"].as_str() {
            conflicts.push(path.to_owned());
        }
        if state == "synchronized"
            || (modern
                && record["result"]
                    .as_str()
                    .is_some_and(|value| lower_first(value) == "succeeded")
                && state == "conflict")
        {
            downloads += usize::from(matches!(action.as_str(), "downloaded" | "deleted"));
            uploads += usize::from(matches!(action.as_str(), "uploaded" | "created"));
        }
        if !file["error"].is_null() && file["error"]["category"] != "Conflict" {
            failed = true;
            if error_category.is_none() {
                error_category = file["error"]["category"].as_str().map(str::to_owned);
            }
            if error_message.is_none() {
                error_message = file["error"]["message"].as_str().map(str::to_owned);
            }
        }
        failed |= state == "failed" && !conflict;
    }
    conflicts.sort();
    conflicts.dedup();
    let mut execution = record["result"].clone();
    if execution == "Failed" && !failed && !conflicts.is_empty() {
        execution = Value::String("Succeeded".into());
    }
    fields.insert("execution_result".into(), execution);
    fields.insert("file_count".into(), files.len().into());
    fields.insert("downloaded_count".into(), downloads.into());
    fields.insert("uploaded_count".into(), uploads.into());
    fields.insert("conflict_count".into(), conflicts.len().into());
    fields.insert("conflicts".into(), serde_json::json!(conflicts));
    if let Some(category) = error_category {
        fields.insert("error_category".into(), category.into());
    }
    if let Some(message) = error_message {
        fields.insert("error_message".into(), message.into());
    }
    fields
}

pub(crate) async fn stage<C: SyncContextDetail, F: SyncFileDetail>(
    root: &Path,
    record: &OrgRepoSyncRecord<C, F>,
    plan: &mut Plan,
) -> Result<(), CoreError> {
    if record.finished_at.is_none() || record.result.is_none() {
        return Err(CoreError::InvalidState("未完成的同步日志不能发布"));
    }
    let time = record.started_at;
    let summary_path = format!("{ROOT}/{time}/summary");
    if transaction::read(root, &summary_path).await?.is_some()
        || transaction::read(root, &format!("{ROOT}/{time}.json"))
            .await?
            .is_some()
    {
        return Err(CoreError::InvalidState("同步历史开始时间已存在"));
    }
    let record_value =
        serde_json::to_value(record).map_err(|_| CoreError::InvalidState("无法编码同步日志"))?;
    let fields = summary_fields(&record_value);
    let mut text = String::new();
    add_line(&mut text, "started_at", time);
    add_line(&mut text, "format_version", 1);
    add_line(&mut text, "sync_id", &record.id);
    for name in [
        "kind",
        "finished_at",
        "result",
        "execution_result",
        "file_count",
        "downloaded_count",
        "uploaded_count",
        "conflict_count",
        "trigger_reason",
        "error_category",
        "error_message",
    ] {
        if let Some(value) = fields.get(name).filter(|value| !value.is_null()) {
            let value = value
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| value.to_string());
            add_line(
                &mut text,
                name,
                if matches!(name, "result" | "execution_result") {
                    lower_first(&value)
                } else {
                    value
                },
            );
        }
    }
    if let Some(paths) = fields.get("conflicts").and_then(Value::as_array) {
        for (index, path) in paths.iter().enumerate() {
            if let Some(path) = path.as_str() {
                add_line(&mut text, &format!("conflict_{index}"), path);
            }
        }
    }
    plan.set(
        root,
        format!("{ROOT}/{time}/context.json"),
        Some(
            serde_json::to_vec(&record_value["context_detail"])
                .map_err(|_| CoreError::InvalidState("无法编码日志上下文"))?,
        ),
    )
    .await?;
    let mut seen = BTreeSet::new();
    for item in &record.files {
        if !seen.insert(&item.relative_path) {
            return Err(CoreError::InvalidState("同步文件日志路径重复"));
        }
        super::validate_relative_path(&item.relative_path)?;
        let mut value =
            serde_json::to_value(item).map_err(|_| CoreError::InvalidState("无法编码文件日志"))?;
        let directory = file_root(time, &item.relative_path);
        if let Some(source) = value["detail"]["synced_source"].as_str().map(str::to_owned) {
            let hash = super::LocalFileVersion::from_bytes(source.as_bytes()).content_hash;
            value["source_hash"] = hash.into();
            if let Some(detail) = value["detail"].as_object_mut() {
                detail.remove("synced_source");
            }
            plan.set(
                root,
                format!("{directory}/{}", filename(&item.relative_path)?),
                Some(source.into_bytes()),
            )
            .await?;
        }
        plan.set(
            root,
            format!("{directory}/record.json"),
            Some(
                serde_json::to_vec(&value)
                    .map_err(|_| CoreError::InvalidState("无法编码文件日志"))?,
            ),
        )
        .await?;
    }
    // 摘要最后入计划；任何失败仍由同一本地事务还原。
    plan.set(root, summary_path, Some(text.into_bytes())).await
}

async fn summary(root: &Path, time: TimestampMs) -> Result<SyncLogRecord, CoreError> {
    let path = format!("{ROOT}/{time}/summary");
    let target = transaction::target(root, &path).await?;
    let file = match fs::File::open(target).await {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(SyncLogRecord {
                key: format!("history-{time}"),
                time,
                data: SyncLogData::default(),
                issues: vec![issue(&path, None, "摘要缺失")],
                legacy: None,
            });
        }
        Err(e) => return Err(io(e)),
    };
    let mut reader = BufReader::new(file);
    let mut object = Map::new();
    let mut seen = BTreeSet::new();
    let mut issues = Vec::new();
    let mut number = 0;
    let mut total = 0;
    loop {
        let mut line = Vec::new();
        let mut exceeded = false;
        let mut ended = false;
        let mut any = false;
        while !ended {
            let buffer = reader.fill_buf().await.map_err(io)?;
            if buffer.is_empty() {
                break;
            }
            any = true;
            let count = buffer
                .iter()
                .position(|byte| *byte == b'\n')
                .map(|i| i + 1)
                .unwrap_or(buffer.len());
            ended = buffer[count - 1] == b'\n';
            total += count;
            if line.len() + count <= MAX_LINE {
                line.extend_from_slice(&buffer[..count]);
            } else {
                exceeded = true;
            }
            reader.consume(count);
            if total > MAX_SUMMARY {
                break;
            }
        }
        if !any {
            break;
        }
        number += 1;
        if exceeded || total > MAX_SUMMARY {
            issues.push(issue(&path, None, &format!("第 {number} 行或摘要大小超限")));
            if total > MAX_SUMMARY {
                break;
            }
            continue;
        }
        let Ok(line) = std::str::from_utf8(&line) else {
            issues.push(issue(&path, None, &format!("第 {number} 行编码无效")));
            continue;
        };
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            continue;
        }
        let Some((raw_key, value)) = line.split_once('=') else {
            issues.push(issue(&path, None, &format!("第 {number} 行缺少等号")));
            continue;
        };
        let key = if raw_key == "sync_id" { "id" } else { raw_key };
        if number == 1 && key != "started_at" {
            issues.push(issue(&path, Some("started_at"), "首行必须为时间"));
        }
        if !seen.insert(key.to_owned()) {
            object.insert(key.into(), Value::Null);
            issues.push(issue(&path, Some(key), "字段重复"));
            continue;
        }
        let Some(value) = unescape(value) else {
            object.insert(key.into(), Value::Null);
            issues.push(issue(&path, Some(key), "转义无效"));
            continue;
        };
        let parsed = if matches!(
            key,
            "started_at"
                | "finished_at"
                | "format_version"
                | "file_count"
                | "downloaded_count"
                | "uploaded_count"
                | "conflict_count"
        ) {
            match value.parse::<u64>() {
                Ok(number) => Value::from(number),
                Err(_) => {
                    issues.push(issue(&path, Some(key), "数字字段无效"));
                    Value::Null
                }
            }
        } else {
            Value::String(value)
        };
        object.insert(key.into(), parsed);
    }
    if object.get("format_version").and_then(Value::as_u64) != Some(1) {
        issues.push(issue(
            &path,
            Some("format_version"),
            "摘要格式版本缺失或不受支持",
        ));
    }
    if object.get("started_at").and_then(Value::as_i64) != Some(time) {
        issues.push(issue(&path, Some("started_at"), "时间缺失或与目录不一致"));
        object.insert("started_at".into(), Value::Null);
    }
    let count = object
        .get("conflict_count")
        .and_then(Value::as_u64)
        .filter(|n| *n <= 10000);
    if let Some(count) = count {
        let paths = (0..count)
            .map(|i| {
                object
                    .get(&format!("conflict_{i}"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .collect::<Option<Vec<_>>>();
        if let Some(paths) = paths {
            object.insert("conflicts".into(), serde_json::json!(paths));
        }
    }
    if object.contains_key("error_category") || object.contains_key("error_message") {
        object.insert("error".into(),serde_json::json!({"category":object.get("error_category"),"message":object.get("error_message")}));
    }
    let (data, more) = SyncLogData::from_json(&Value::Object(object), &path);
    issues.extend(more);
    let key = data
        .id
        .as_ref()
        .filter(|id| !id.is_empty())
        .cloned()
        .unwrap_or_else(|| format!("history-{time}"));
    Ok(SyncLogRecord {
        key,
        data,
        issues,
        time,
        legacy: None,
    })
}
async fn legacy(root: &Path, time: TimestampMs) -> Result<SyncLogRecord, CoreError> {
    let path = format!("{ROOT}/{time}.json");
    let bytes = transaction::read(root, &path)
        .await?
        .ok_or(CoreError::InvalidInput("同步日志已不存在"))?;
    let value = match serde_json::from_slice::<Value>(&bytes) {
        Ok(value) => value,
        Err(error) => {
            return Ok(SyncLogRecord {
                key: format!("history-{time}"),
                data: SyncLogData::default(),
                time,
                legacy: Some(Value::Null),
                issues: vec![issue(
                    &path,
                    None,
                    &format!(
                        "JSON 语法无效，第 {} 行第 {} 列",
                        error.line(),
                        error.column()
                    ),
                )],
            });
        }
    };
    let (mut data, mut issues) = SyncLogData::from_json(&value, &path);
    if data.started_at != Some(time) {
        data.started_at = None;
        issues.push(issue(&path, Some("started_at"), "时间缺失或与文件名不一致"));
    }
    // 汇总只使用字段校验通过的文件元素，结构异常另行报告，不让一个旧字段摧毁整轮。
    let mut summary_value = value.clone();
    let mut validated = Vec::new();
    if let Some(files) = value.get("files") {
        if let Some(files) = files.as_array() {
            for (index, file) in files.iter().enumerate() {
                let file_path = format!("{path}:files[{index}]");
                let (data, mut file_issues) = SyncLogData::from_json(file, &file_path);
                for (name, missing) in [
                    ("relative_path", data.relative_path.is_none()),
                    ("action", data.action.is_none()),
                    ("state", data.state.is_none()),
                ] {
                    if missing {
                        file_issues.push(issue(&file_path, Some(name), "文件统计字段缺失或无效"));
                    }
                }
                if file_issues.is_empty() {
                    validated.push(file.clone());
                } else {
                    issues.append(&mut file_issues);
                }
            }
        } else {
            issues.push(issue(&path, Some("files"), "文件列表类型无效"));
        }
    }
    if let Some(object) = summary_value.as_object_mut() {
        object.insert("files".into(), Value::Array(validated));
    }
    let mut fields = summary_fields(&summary_value);
    if fields.contains_key("error_category") || fields.contains_key("error_message") {
        fields.insert("error".into(),serde_json::json!({"category":fields.get("error_category"),"message":fields.get("error_message")}));
    }
    if !value.get("files").is_some_and(Value::is_array) {
        issues.push(issue(&path, Some("files"), "文件列表缺失或无效"));
    }

    // 文件字段不完整时不把已读子集的数量伪装成完整统计。
    if issues
        .iter()
        .any(|issue| issue.field.as_deref() == Some("files") || issue.path.contains(":files["))
    {
        for key in [
            "file_count",
            "downloaded_count",
            "uploaded_count",
            "conflict_count",
            "conflicts",
            "execution_result",
        ] {
            fields.remove(key);
        }
    }
    let (mut aggregated, _) = SyncLogData::from_json(&Value::Object(fields), &path);
    aggregated.id = data.id;
    aggregated.kind = data.kind;
    aggregated.started_at = data.started_at;
    aggregated.finished_at = data.finished_at;
    aggregated.result = data.result;
    aggregated.trigger_reason = data.trigger_reason;
    let key = aggregated
        .id
        .as_ref()
        .filter(|id| !id.is_empty())
        .cloned()
        .unwrap_or_else(|| format!("history-{time}"));
    Ok(SyncLogRecord {
        key,
        data: aggregated,
        issues,
        time,
        legacy: Some(value),
    })
}

fn unreadable(time: TimestampMs, path: &str, error: CoreError) -> SyncLogRecord {
    SyncLogRecord {
        key: format!("history-{time}"),
        time,
        data: SyncLogData::default(),
        legacy: None,
        issues: vec![issue(path, None, &error.to_string())],
    }
}

pub(crate) async fn list(root: &Path) -> Result<Vec<SyncLogRecord>, CoreError> {
    let mut records = Vec::new();
    for time in occupied_times(root).await? {
        let modern = format!("{ROOT}/{time}/summary");
        // 先检查目录类型，旧版本可能有同名目录与 JSON，但目录中没有新摘要。
        let directory = fs::symlink_metadata(root.join(format!("{ROOT}/{time}"))).await;
        if directory
            .as_ref()
            .is_ok_and(|meta| meta.file_type().is_symlink())
        {
            records.push(unreadable(
                time,
                &format!("{ROOT}/{time}"),
                CoreError::InvalidState("同步日志目录含符号链接"),
            ));
            continue;
        }
        let modern_exists = directory.as_ref().is_ok_and(|meta| meta.is_dir())
            && fs::try_exists(root.join(&modern)).await.map_err(io)?;
        if modern_exists {
            records.push(
                summary(root, time)
                    .await
                    .unwrap_or_else(|error| unreadable(time, &modern, error)),
            );
        } else if fs::try_exists(root.join(format!("{ROOT}/{time}.json")))
            .await
            .map_err(io)?
        {
            records.push(
                legacy(root, time).await.unwrap_or_else(|error| {
                    unreadable(time, &format!("{ROOT}/{time}.json"), error)
                }),
            );
        } else if directory.as_ref().is_ok_and(|meta| meta.is_dir()) {
            records.push(
                summary(root, time)
                    .await
                    .unwrap_or_else(|error| unreadable(time, &modern, error)),
            );
        }
    }
    Ok(records)
}
pub(crate) async fn locate(root: &Path, id: &str) -> Result<SyncLogRecord, CoreError> {
    // 新身份及目录回退定位符含时间，直接读取这一轮，避免展开时遍历全部历史。
    if let Some(time) = id
        .rsplit('-')
        .next()
        .and_then(|value| value.parse::<TimestampMs>().ok())
    {
        let path = format!("{ROOT}/{time}/summary");
        if fs::try_exists(transaction::target(root, &path).await?)
            .await
            .map_err(io)?
        {
            let record = summary(root, time).await?;
            if record.key == id {
                return Ok(record);
            }
        } else if fs::try_exists(transaction::target(root, &format!("{ROOT}/{time}.json")).await?)
            .await
            .map_err(io)?
        {
            let record = legacy(root, time).await?;
            if record.key == id {
                return Ok(record);
            }
        }
    }
    list(root)
        .await?
        .into_iter()
        .find(|record| record.key == id)
        .ok_or(CoreError::InvalidInput("同步日志已不存在"))
}
pub(crate) async fn file_records(
    root: &Path,
    record: &SyncLogRecord,
) -> Result<Vec<SyncLogRecord>, CoreError> {
    let time = record.time;
    let mut records = Vec::new();
    if let Some(legacy) = &record.legacy {
        if let Some(files) = legacy["files"].as_array() {
            for (index, file) in files.iter().enumerate() {
                let (data, issues) =
                    SyncLogData::from_json(file, &format!("{ROOT}/{time}.json:files[{index}]"));
                records.push(SyncLogRecord {
                    key: format!("file-{index}"),
                    data,
                    issues,
                    time,
                    legacy: Some(file.clone()),
                });
            }
        }
        return Ok(records);
    }
    let directory = format!("{ROOT}/{time}/files");
    let path = safe_directory(root, &directory).await?;
    let mut entries = match fs::read_dir(path).await {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            if record.data.file_count.is_some_and(|count| count > 0) {
                records.push(SyncLogRecord {
                    key: "incomplete".into(),
                    time,
                    data: SyncLogData::default(),
                    legacy: None,
                    issues: vec![issue(&directory, None, "文件日志目录缺失")],
                });
            }
            return Ok(records);
        }
        Err(e) => return Err(io(e)),
    };
    while let Some(entry) = entries.next_entry().await.map_err(io)? {
        let key = entry.file_name().to_string_lossy().into_owned();
        if key.len() != 64 || !key.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            continue;
        }
        if let Err(error) = safe_directory(root, &format!("{directory}/{key}")).await {
            records.push(unreadable(time, &format!("{directory}/{key}"), error));
            continue;
        }
        let record_path = format!("{directory}/{key}/record.json");
        let value = match transaction::read(root, &record_path).await {
            Ok(Some(bytes)) => serde_json::from_slice::<Value>(&bytes).ok(),
            Ok(None) => None,
            Err(error) => {
                records.push(unreadable(time, &record_path, error));
                continue;
            }
        };
        let (data, mut issues) = match &value {
            Some(value) => SyncLogData::from_json(value, &record_path),
            None => (
                SyncLogData::default(),
                vec![issue(&record_path, None, "文件日志缺失或 JSON 无效")],
            ),
        };
        let mut data = data;
        if data
            .relative_path
            .as_ref()
            .is_some_and(|path| file_key(path) != key)
        {
            data.relative_path = None;
            issues.push(issue(
                &record_path,
                Some("relative_path"),
                "文件路径与目录键不一致",
            ));
        }
        records.push(SyncLogRecord {
            key,
            data,
            issues,
            time,
            legacy: value,
        });
    }
    records.sort_by(|a, b| {
        a.data
            .relative_path
            .cmp(&b.data.relative_path)
            .then(a.key.cmp(&b.key))
    });
    if record
        .data
        .file_count
        .is_some_and(|count| count != records.len())
    {
        records.push(SyncLogRecord {
            key: "incomplete".into(),
            time,
            data: SyncLogData::default(),
            legacy: None,
            issues: vec![issue(&directory, None, "文件日志数量与摘要不一致")],
        });
    }
    Ok(records)
}

async fn safe_directory(root: &Path, path: &str) -> Result<std::path::PathBuf, CoreError> {
    super::validate_relative_path(path)?;
    let mut current = root.to_path_buf();
    for part in path.split('/') {
        current.push(part);
        match fs::symlink_metadata(&current).await {
            Ok(meta) if meta.file_type().is_symlink() || !meta.is_dir() => {
                return Err(CoreError::Store("同步日志目录不安全".into()));
            }
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(io(e)),
        }
    }
    Ok(current)
}

pub(crate) async fn strict_record<C: SyncContextDetail, F: SyncFileDetail>(
    root: &Path,
    record: &SyncLogRecord,
) -> Result<OrgRepoSyncRecord<C, F>, CoreError> {
    let data = &record.data;
    let required = |name: &str| CoreError::Store(format!("同步日志缺少有效字段: {name}"));
    let id = data
        .id
        .clone()
        .filter(|id| !id.is_empty())
        .ok_or_else(|| required("id"))?;
    let kind = data.kind.clone().ok_or_else(|| required("kind"))?;
    let started_at = data
        .started_at
        .filter(|time| *time == record.time)
        .ok_or_else(|| required("started_at"))?;
    let finished_at = data.finished_at.ok_or_else(|| required("finished_at"))?;
    let result = data
        .result
        .as_deref()
        .and_then(parse_result)
        .ok_or_else(|| required("result"))?;
    let context = if let Some(value) = &record.legacy {
        value
            .get("context_detail")
            .cloned()
            .ok_or_else(|| required("context_detail"))?
    } else {
        let bytes = transaction::read(root, &format!("{ROOT}/{}/context.json", record.time))
            .await?
            .ok_or_else(|| required("context_detail"))?;
        serde_json::from_slice(&bytes).map_err(|_| required("context_detail"))?
    };
    let context_detail = serde_json::from_value(context).map_err(|_| required("context_detail"))?;
    let mut files = Vec::new();
    for file in file_records(root, record).await? {
        files.push(strict_file(root, &file).await?);
    }
    let trigger_reason = data
        .trigger_reason
        .as_ref()
        .and_then(|reason| serde_json::from_value(Value::String(reason.clone())).ok());
    Ok(OrgRepoSyncRecord {
        id,
        kind,
        trigger_reason,
        started_at,
        finished_at: Some(finished_at),
        result: Some(result),
        context_detail,
        files,
    })
}
pub(crate) fn parse_result(value: &str) -> Option<super::OrgRepoSyncResult> {
    match value {
        "succeeded" => Some(super::OrgRepoSyncResult::Succeeded),
        "failed" => Some(super::OrgRepoSyncResult::Failed),
        "cancelled" => Some(super::OrgRepoSyncResult::Cancelled),
        "interrupted" => Some(super::OrgRepoSyncResult::Interrupted),
        _ => None,
    }
}
pub(crate) async fn strict_file<F: SyncFileDetail>(
    root: &Path,
    file: &SyncLogRecord,
) -> Result<super::OrgRepoSyncFileRecord<F>, CoreError> {
    if file.data.relative_path.is_none() || file.data.action.is_none() || file.data.state.is_none()
    {
        return Err(CoreError::InvalidState(
            "文件日志缺少操作所需的安全路径、动作或状态",
        ));
    }
    let mut value = file
        .legacy
        .clone()
        .ok_or(CoreError::InvalidState("文件日志不可读"))?;
    if let Some(hash) = &file.data.source_hash {
        let path = file
            .data
            .relative_path
            .as_ref()
            .ok_or(CoreError::InvalidState("文件日志缺少安全路径"))?;
        let bytes = transaction::read(
            root,
            &format!("{}/{}", file_root(file.time, path), filename(path)?),
        )
        .await?
        .ok_or(CoreError::InvalidState("历史原文缺失"))?;
        if super::LocalFileVersion::from_bytes(&bytes).content_hash != *hash {
            return Err(CoreError::Store("历史原文 hash 不一致".into()));
        }
        let source =
            String::from_utf8(bytes).map_err(|_| CoreError::InvalidState("历史原文不是 UTF-8"))?;
        let detail = value
            .get_mut("detail")
            .and_then(Value::as_object_mut)
            .ok_or(CoreError::InvalidState("文件日志 detail 无效"))?;
        detail.insert("synced_source".into(), source.into());
    }
    serde_json::from_value(value).map_err(|_| CoreError::InvalidState("文件日志缺少操作所需字段"))
}
pub(crate) async fn strict_records<P: super::SyncPolicy>(
    root: &Path,
) -> Result<Vec<OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>>, CoreError> {
    let mut records = Vec::new();
    for entry in list(root).await? {
        let record = strict_record(root, &entry).await?;
        if record.kind != P::KIND {
            return Err(CoreError::Store("同步历史 kind 与策略不一致".into()));
        }
        if records.iter().any(
            |existing: &OrgRepoSyncRecord<P::ContextDetail, P::FileDetail>| {
                existing.id == record.id
            },
        ) {
            return Err(CoreError::InvalidState("同步历史记录 ID 重复"));
        }
        records.push(record);
    }
    Ok(records)
}

pub(crate) async fn selected_file(
    root: &Path,
    record: &SyncLogRecord,
    path: &str,
) -> Result<SyncLogRecord, CoreError> {
    super::validate_relative_path(path)?;
    if record.legacy.is_some() {
        return file_records(root, record)
            .await?
            .into_iter()
            .find(|entry| entry.data.relative_path.as_deref() == Some(path))
            .ok_or(CoreError::InvalidInput("同步文件日志不存在"));
    }
    let key = file_key(path);
    let record_path = format!("{}/record.json", file_root(record.time, path));
    let bytes = transaction::read(root, &record_path)
        .await?
        .ok_or(CoreError::InvalidInput("同步文件日志不存在"))?;
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|_| CoreError::InvalidState("文件日志 JSON 不可读"))?;
    let (data, issues) = SyncLogData::from_json(&value, &record_path);
    if data.relative_path.as_deref() != Some(path) {
        return Err(CoreError::InvalidState("文件日志缺少匹配的安全路径"));
    }
    Ok(SyncLogRecord {
        key,
        data,
        issues,
        time: record.time,
        legacy: Some(value),
    })
}

impl super::OrgRepo {
    pub async fn sync_log_summaries(&self) -> Result<Vec<SyncLogRecord>, CoreError> {
        let root = Path::new(&self.root_directory);
        let _guard = super::access::enter(root, &self.id).await?;
        list(root).await
    }
    pub async fn sync_log_detail(&self, id: &str) -> Result<SyncLogDetail, CoreError> {
        let root = Path::new(&self.root_directory);
        let _guard = super::access::enter(root, &self.id).await?;
        let summary = locate(root, id).await?;
        let files = file_records(root, &summary).await?;
        Ok(SyncLogDetail { summary, files })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        OrgRepo, OrgRepoSyncFileAction, OrgRepoSyncFileRecord, OrgRepoSyncFileState,
        OrgRepoSyncResult,
    };
    use serde_json::json;

    fn root() -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "org-sync-log-{}",
            super::super::service::generate_uuid().unwrap()
        ));
        std::fs::create_dir_all(root.join(".sync/history")).unwrap();
        root
    }
    fn record(time: i64) -> OrgRepoSyncRecord<Value, Value> {
        let mut record = OrgRepoSyncRecord::new(format!("test-{time}"), time)
            .unwrap()
            .with_kind("test");
        record.trigger_reason = Some(crate::SyncTriggerReason::Manual);
        record
            .finish(OrgRepoSyncResult::Succeeded, time + 1)
            .unwrap();
        record
    }
    async fn publish(root: &Path, record: &OrgRepoSyncRecord<Value, Value>) {
        let mut plan = Plan::default();
        stage(root, record, &mut plan).await.unwrap();
        plan.commit(root).await.unwrap();
    }
    async fn write_summary(root: &Path, bytes: impl AsRef<[u8]>) {
        fs::create_dir_all(root.join(".sync/history/10"))
            .await
            .unwrap();
        fs::write(root.join(".sync/history/10/summary"), bytes)
            .await
            .unwrap();
    }

    #[test]
    fn json_fields_fail_independently_and_metadata_remains_optional() {
        let (data, issues) = SyncLogData::from_json(
            &json!({"started_at":"bad","result":"Succeeded","action":7,"relative_path":"a.org","trigger_reason":"appStartup","event":{"bad":true},"detail":{"unknown":42}}),
            "fixture",
        );
        assert_eq!(data.started_at, None);
        assert_eq!(data.action, None);
        assert_eq!(data.event, None);
        assert_eq!(data.result.as_deref(), Some("succeeded"));
        assert_eq!(data.relative_path.as_deref(), Some("a.org"));
        assert_eq!(data.trigger_reason.as_deref(), Some("appStartup"));
        assert_eq!(data.detail.unwrap()["unknown"], 42);
        assert_eq!(issues.len(), 3);
    }

    #[tokio::test]
    async fn summary_first_line_and_zero_file_results_roundtrip() {
        let root = root();
        for (time, result) in [
            (10, OrgRepoSyncResult::Succeeded),
            (20, OrgRepoSyncResult::Failed),
            (30, OrgRepoSyncResult::Cancelled),
        ] {
            let mut record = record(time);
            record.result = Some(result);
            publish(&root, &record).await;
            let bytes = fs::read(root.join(format!(".sync/history/{time}/summary")))
                .await
                .unwrap();
            assert!(bytes.starts_with(format!("started_at={time}\nformat_version=1\n").as_bytes()));
            let entry = summary(&root, time).await.unwrap();
            assert!(entry.issues.is_empty(), "{:?}", entry.issues);
            assert_eq!(entry.data.file_count, Some(0));
            assert_eq!(entry.data.conflict_count, Some(0));
            assert_eq!(
                strict_record::<Value, Value>(&root, &entry).await.unwrap(),
                record
            );
        }
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn summary_is_line_oriented_and_isolates_utf8_escapes_duplicates_and_limits() {
        let root = root();
        let mut bytes=b"started_at=10\r\nformat_version=1\r\nresult=succeeded\r\nfile_count=2\r\nfile_count=3\r\ntrigger_reason=appBackground\r\nerror_message=a=b\\nnext\\tline\\\\end\r\n".to_vec();
        bytes.extend_from_slice(b"event=\xff\n");
        bytes.extend_from_slice(format!("ignored={}\n", "x".repeat(MAX_LINE + 1)).as_bytes());
        bytes.extend_from_slice(b"downloaded_count=1\nuploaded_count=bad\nfuture_field=ok\n");
        write_summary(&root, bytes).await;
        let entry = summary(&root, 10).await.unwrap();
        assert_eq!(entry.data.started_at, Some(10));
        assert_eq!(entry.data.file_count, None);
        assert_eq!(entry.data.downloaded_count, Some(1));
        assert_eq!(entry.data.uploaded_count, None);
        assert_eq!(entry.data.trigger_reason.as_deref(), Some("appBackground"));
        assert_eq!(entry.data.error.unwrap()["message"], "a=b\nnext\tline\\end");
        assert!(entry.issues.len() >= 4);
        write_summary(
            &root,
            b"result=succeeded\nstarted_at=11\nformat_version=99\n",
        )
        .await;
        let entry = summary(&root, 10).await.unwrap();
        assert_eq!(entry.data.started_at, None);
        assert_eq!(entry.data.result.as_deref(), Some("succeeded"));
        assert!(entry.issues.len() >= 3);
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn legacy_reasons_and_bad_file_siblings_remain_readable_without_rewriting() {
        let root = root();
        for (time, reason) in [
            (10, "appStartup"),
            (20, "appBackground"),
            (30, "futureReason"),
        ] {
            let mut value = serde_json::to_value(record(time)).unwrap();
            value["trigger_reason"] = reason.into();
            value["files"] = json!([{"relative_path":"good.org","action":"Downloaded","state":"Synchronized"},{"relative_path":"bad.org","action":false,"state":"Synchronized"},{}]);
            let original = serde_json::to_vec(&value).unwrap();
            let path = root.join(format!(".sync/history/{time}.json"));
            fs::write(&path, &original).await.unwrap();
            let entry = legacy(&root, time).await.unwrap();
            assert_eq!(entry.data.trigger_reason.as_deref(), Some(reason));
            assert_eq!(entry.data.result.as_deref(), Some("succeeded"));
            assert_eq!(entry.data.downloaded_count, None);
            assert!(!entry.issues.is_empty());
            let files = file_records(&root, &entry).await.unwrap();
            assert_eq!(files.len(), 3);
            assert_eq!(files[0].data.action.as_deref(), Some("downloaded"));
            assert_eq!(files[1].data.relative_path.as_deref(), Some("bad.org"));
            assert_eq!(fs::read(path).await.unwrap(), original);
        }
        fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn summaries_do_not_read_file_logs_and_selected_original_ignores_corrupt_siblings() {
        let root = root();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        repo.load::<EmptySync>().await.unwrap();
        let mut record = record(10);
        for path in ["a.org", "b.org"] {
            record.files.push(
                OrgRepoSyncFileRecord::new(
                    path.into(),
                    OrgRepoSyncFileAction::Downloaded,
                    OrgRepoSyncFileState::Synchronized,
                )
                .unwrap()
                .with_local_version(Some(crate::LocalFileVersion::from_bytes(b"* TODO Saved\n")))
                .with_detail(json!({"synced_source":"* TODO Saved\n"})),
            );
        }
        publish(&root, &record).await;
        let bad = root.join(format!("{}/record.json", file_root(10, "b.org")));
        fs::write(bad, b"{").await.unwrap();
        let entries = repo.sync_log_summaries().await.unwrap();
        assert!(entries[0].issues.is_empty());
        assert_eq!(entries[0].data.file_count, Some(2));
        assert!(
            repo.sync_log_detail("test-10")
                .await
                .unwrap()
                .files
                .iter()
                .any(|file| !file.issues.is_empty())
        );
        assert_eq!(
            repo.history_file("test-10", "a.org", false)
                .await
                .unwrap()
                .source_bytes(),
            b"* TODO Saved\n"
        );
        fs::write(
            root.join(format!("{}/a.org", file_root(10, "a.org"))),
            b"tampered",
        )
        .await
        .unwrap();
        assert!(
            repo.history_file("test-10", "a.org", false)
                .await
                .unwrap_err()
                .to_string()
                .contains("不一致")
        );
        fs::remove_dir_all(root).await.unwrap();
    }

    struct EmptySync;
    impl crate::SyncPolicy for EmptySync {
        const KIND: &'static str = "test";
        type ContextDetail = Value;
        type FileDetail = Value;
        async fn check_remote_changes(
            &self,
            _: &crate::RemoteCheckContext<'_>,
        ) -> Result<crate::RemoteChangeState, CoreError> {
            Ok(crate::RemoteChangeState::Unknown)
        }
        async fn synchronize(
            &self,
            context: &mut crate::SyncContext<'_>,
            _: &crate::SyncCancellation,
            _: &crate::SyncProgressReporter,
        ) -> Result<OrgRepoSyncRecord<Value, Value>, CoreError> {
            Ok(record(context.started_at))
        }
    }

    #[tokio::test]
    async fn corrupt_history_never_blocks_new_sync_or_gets_overwritten() {
        let root = root();
        let mut repo = OrgRepo::new(root.to_string_lossy().into()).unwrap();
        fs::write(root.join(".sync/history/1.json"), b"{")
            .await
            .unwrap();
        // 数字目录内即使没有可读摘要也会预留时间槽，新同步无需解释它。
        fs::create_dir_all(root.join(".sync/history/2/summary"))
            .await
            .unwrap();
        let result = repo
            .sync_at(
                &EmptySync,
                3,
                &crate::SyncCancellation::default(),
                &crate::SyncProgressReporter::default(),
            )
            .await
            .unwrap();
        assert_eq!(result.result, Some(OrgRepoSyncResult::Succeeded));
        assert_eq!(
            fs::read(root.join(".sync/history/1.json")).await.unwrap(),
            b"{"
        );
        assert!(
            repo.sync_at(
                &EmptySync,
                1,
                &crate::SyncCancellation::default(),
                &crate::SyncProgressReporter::default()
            )
            .await
            .is_err()
        );
        assert!(
            repo.sync_at(
                &EmptySync,
                2,
                &crate::SyncCancellation::default(),
                &crate::SyncProgressReporter::default()
            )
            .await
            .is_err()
        );
        fs::remove_dir_all(root).await.unwrap();
    }
}
