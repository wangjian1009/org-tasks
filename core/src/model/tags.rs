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

fn configured_tag(token: &str) -> Option<&str> {
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
            for tag in value.split(':').map(str::trim) {
                push_unique(&mut tags, tag);
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

    pub(crate) fn support_tags(&self) -> Option<SupportTags> {
        let mut tags = Vec::new();
        let mut groups = Vec::new();
        let mut group: Option<Vec<String>> = None;
        let mut configured = false;
        for value in self.file_keywords.values("TAGS") {
            configured = true;
            for token in value.split_whitespace() {
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
                    if let Some(group) = &mut group {
                        push_unique(group, tag);
                    }
                }
            }
        }
        configured.then_some(SupportTags { tags, groups })
    }
}
