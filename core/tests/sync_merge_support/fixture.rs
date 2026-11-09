use super::{Result, ensure};
use serde::Deserialize;
use std::path::{Component, Path};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Case {
    pub format_version: u32,
    pub purpose: String,
    pub rounds: Vec<Round>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Round {
    pub label: String,
    pub input: Input,
    pub expected: Expected,
    #[serde(default)]
    pub inspect: Vec<Inspect>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Input {
    pub base: Data,
    pub local: Data,
    pub remote: Data,
}

#[derive(Deserialize)]
#[serde(untagged)]
pub enum Data {
    File(String),
    Previous(Previous),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Previous {
    pub round: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Expected {
    pub content: Option<String>,
    pub same_bytes_as_round: Option<usize>,
    pub error: Option<String>,
}

#[derive(Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
pub enum Inspect {
    #[serde(rename_all = "camelCase")]
    ConflictSubtree {
        origin_id: Option<String>,
        candidate_alias: String,
        operation: String,
        root_only_tag: String,
        placement: Placement,
        parent_titles: Vec<String>,
        origin_titles: Vec<String>,
        source: String,
        after_id: Option<String>,
        before_id: Option<String>,
    },
}

#[derive(Deserialize, PartialEq)]
pub enum Placement {
    AfterOriginSubtree,
    Anchored,
}

pub fn safe_path(path: &str) -> Result<()> {
    ensure(
        !path.is_empty()
            && !path.contains('\\')
            && Path::new(path)
                .components()
                .all(|part| matches!(part, Component::Normal(_)))
            && !path.split('/').any(|part| part == ".sync"),
        format!("不安全的用例路径: {path}"),
    )
}

pub fn read(case: &Path, relative: &str) -> Result<Vec<u8>> {
    safe_path(relative)?;
    let mut path = case.to_path_buf();
    for part in Path::new(relative).components() {
        path.push(part);
        let meta = std::fs::symlink_metadata(&path)?;
        ensure(!meta.file_type().is_symlink(), "用例路径不允许符号链接")?;
    }
    ensure(path.is_file(), "内容输入必须是普通文件")?;
    Ok(std::fs::read(path)?)
}
