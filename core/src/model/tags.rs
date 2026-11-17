use super::OrgFile;
use serde::Serialize;

pub(crate) const ATTACH_TAG: &str = "ATTACH";

/// 可配置标签及互斥组；配置缺失与显式空配置由外层 Option 区分。
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SupportTags {
    pub tags: Vec<String>,
    pub groups: Vec<Vec<String>>,
}

fn valid_tag(tag: &str) -> bool {
    !tag.is_empty() && tag.chars().all(|c| c.is_alphanumeric() || "_@#%".contains(c))
}

fn push_unique(tags: &mut Vec<String>, tag: &str) {
    if valid_tag(tag) && !tags.iter().any(|value| value == tag) {
        tags.push(tag.to_owned());
    }
}

pub(super) fn configured_tag(token: &str) -> Option<&str> {
    let tag = if let Some((tag, shortcut)) = token.split_once('(') {
        if shortcut.strip_suffix(')')?.chars().count() != 1 {
            return None;
        }
        tag
    } else {
        token
    };
    valid_tag(tag).then_some(tag)
}

// 单条 TAGS 声明的候选；分组及快捷键不混入显示名称。
pub(super) fn header_tag_names(value: &str) -> Vec<String> {
    let mut names = Vec::new();
    for tag in value.split_whitespace().filter_map(configured_tag) {
        push_unique(&mut names, tag);
    }
    names
}

// 文件头单条 FILETAGS 使用与有效文件标签相同的名称校验，保留内部用途标签。
pub(super) fn header_file_tag_names(value: &str) -> Vec<String> {
    let mut names = Vec::new();
    for tag in value.split(':').map(str::trim) {
        push_unique(&mut names, tag);
    }
    names
}

impl OrgFile {
    /// 具有内部用途的标签；宿主可隐藏展示，但不得据此改写原文或查询条件。
    pub fn special_tags(&self) -> Vec<String> {
        ["project", super::REFILE_TAG, super::ARCHIVE_TAG, super::CONFLICT_TAG, ATTACH_TAG]
            .into_iter().map(str::to_owned).collect()
    }

    /// 当前文件的有效 FILETAGS，保留内部标签供调用方区分用途。
    pub fn file_tags(&self) -> Vec<String> {
        let mut tags = Vec::new();
        for value in self.file_keywords.values("FILETAGS") {
            for tag in header_file_tag_names(value) {
                push_unique(&mut tags, &tag);
            }
        }
        tags
    }

    /// 文件头定义的候选标签；TAGS 只提供候选，不为任务赋标签。
    pub fn tag_options(&self) -> Vec<String> {
        self.support_tags().map_or_else(Vec::new, |config| config.tags)
    }

    /// TAGS 中花括号定义的互斥组，不将快捷键或组标记作为标签。
    pub fn tag_groups(&self) -> Vec<Vec<String>> {
        self.support_tags().map_or_else(Vec::new, |config| config.groups)
    }

    /// 文件头 TAGS 的显示行，保留声明顺序与显式换行，不改变候选及互斥规则。
    pub fn tag_rows(&self) -> Vec<Vec<String>> {
        self.configured_tags().1
    }

    pub(crate) fn support_tags(&self) -> Option<SupportTags> {
        self.configured_tags().0
    }

    fn configured_tags(&self) -> (Option<SupportTags>, Vec<Vec<String>>) {
        let mut tags = Vec::new();
        let mut groups = Vec::new();
        let mut rows = Vec::new();
        let mut group: Option<Vec<String>> = None;
        let mut configured = false;
        for value in self.file_keywords.values("TAGS") {
            configured = true;
            let mut row = Vec::new();
            for token in value.split_whitespace() {
                if token == "\\n" {
                    if !row.is_empty() { rows.push(std::mem::take(&mut row)); }
                    continue;
                }
                if token == "{" {
                    group = Some(Vec::new());
                    continue;
                }
                if token == "}" {
                    if let Some(values) = group.take().filter(|values| !values.is_empty()) {
                        groups.push(values);
                    }
                    continue;
                }
                if let Some(tag) = configured_tag(token) {
                    if tag == super::REFILE_TAG || tag == super::ARCHIVE_TAG || tag == ATTACH_TAG {
                        continue;
                    }
                    push_unique(&mut tags, tag);
                    push_unique(&mut row, tag);
                    if let Some(group) = &mut group {
                        push_unique(group, tag);
                    }
                }
            }
            if !row.is_empty() { rows.push(row); }
        }
        (configured.then_some(SupportTags { tags, groups }), rows)
    }
}
