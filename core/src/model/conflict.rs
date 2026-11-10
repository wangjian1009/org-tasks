//! 文件尾部的冲突容器；查询与普通编辑仅依据自有／祖先 CONFLICT 标签划定边界。
use super::{CoreError, OrgFile};
use orgize::ast::Headline;
use std::ops::Range;

pub(crate) const CONFLICT_CONTAINER_TITLE: &str = "同步冲突";
pub(crate) const CONFLICT_POINT_ID: &str = "CONFILICT_ID";

#[derive(Clone)]
pub(crate) struct ConflictPoint {
    pub id: String,
    pub source: String,
}

pub(crate) fn point_id(headline: &Headline) -> Option<String> {
    headline
        .properties()?
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(CONFLICT_POINT_ID))
        .map(|(_, value)| value.to_string())
}

pub(crate) fn container(file: &OrgFile) -> Option<Headline> {
    file.syntax().document().headlines().find(|headline| {
        headline.level() == 1
            && headline.tags().any(|tag| tag == super::CONFLICT_TAG)
            && headline.title_raw().trim_end() == CONFLICT_CONTAINER_TITLE
    })
}

pub(crate) fn points(file: &OrgFile) -> Result<Vec<ConflictPoint>, CoreError> {
    let Some(container) = container(file) else {
        return Ok(Vec::new());
    };
    let mut ids = std::collections::BTreeSet::new();
    container
        .headlines()
        .map(|headline| {
            let id =
                point_id(&headline).ok_or(CoreError::InvalidState("冲突点缺少 CONFILICT_ID"))?;
            if id.is_empty() || !ids.insert(id.clone()) {
                return Err(CoreError::InvalidState("冲突点 ID 为空或重复"));
            }
            let range = usize::from(headline.start())..usize::from(headline.end());
            Ok(ConflictPoint {
                id,
                source: String::from_utf8(file.source_bytes()[range].to_vec()).expect("UTF-8"),
            })
        })
        .collect()
}

/// 容器生成时单独追加一个分隔换行；分隔符属于整个冲突块，移除时一并恢复原始末尾状态。
pub(crate) fn block_range(file: &OrgFile, headline: &Headline) -> Range<usize> {
    let mut start = usize::from(headline.start());
    if start > 0 && file.source_bytes()[start - 1] == b'\n' {
        start -= 1;
        if start > 0 && file.source_bytes()[start - 1] == b'\r' {
            start -= 1;
        }
    }
    start..usize::from(headline.end())
}

pub(crate) fn main_source(file: &OrgFile) -> Vec<u8> {
    let Some(container) = container(file) else {
        return file.source_bytes().to_vec();
    };
    let range = block_range(file, &container);
    let mut source = file.source_bytes().to_vec();
    source.drain(range);
    source
}

pub(crate) fn append_points(file: &OrgFile, main: &[u8], points: &[ConflictPoint]) -> Vec<u8> {
    if points.is_empty() {
        return main.to_vec();
    }
    let newline = if file.source_bytes().windows(2).any(|v| v == b"\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let mut source = main.to_vec();
    source.extend_from_slice(
        format!("{newline}* {CONFLICT_CONTAINER_TITLE} :CONFLICT:{newline}").as_bytes(),
    );
    for point in points {
        source.extend_from_slice(point.source.as_bytes());
        if !point.source.ends_with('\n') {
            source.extend_from_slice(newline.as_bytes());
        }
    }
    source
}

pub(crate) fn discard(file: &mut OrgFile, id: &str) -> Result<(), CoreError> {
    let container = container(file).ok_or(CoreError::InvalidInput("文件没有冲突容器"))?;
    let children = container.headlines().collect::<Vec<_>>();
    let targets = children
        .iter()
        .filter(|headline| point_id(headline).as_deref() == Some(id))
        .collect::<Vec<_>>();
    if targets.len() != 1 {
        return Err(CoreError::InvalidInput("冲突点不存在或 ID 重复，请刷新"));
    }
    let range = if children.len() == 1 {
        block_range(file, &container)
    } else {
        usize::from(targets[0].start())..usize::from(targets[0].end())
    };
    file.source_bytes.drain(range);
    file.reparse()
}

impl OrgFile {
    /// 与文件对象一起取得的定位信息，不提供另一套差异展示接口。
    pub fn conflict_ids(&self) -> Vec<String> {
        container(self)
            .into_iter()
            .flat_map(|headline| headline.headlines())
            .filter_map(|headline| point_id(&headline))
            .collect()
    }
}
