//! 文件优先级配置与分类；字母名称保留 Org 原文，语义统一由 Core 生成。
use super::{CoreError, OrgFile, file_keywords::FileKeywords};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PeriodCategory {
    Hight,
    Middle,
    Low,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskPriority {
    pub name: String,
    pub category: Option<PeriodCategory>,
}

pub(super) fn parse(
    syntax: &orgize::Org,
    setup: &str,
) -> Result<(Vec<TaskPriority>, TaskPriority), CoreError> {
    let local = FileKeywords::parse(syntax, "");
    let setup = FileKeywords::parse(&orgize::Org::parse(setup), "");
    let Some(value) = local.get("PRIORITIES").or_else(|| setup.get("PRIORITIES")) else {
        return Ok((
            Vec::new(),
            TaskPriority {
                name: "B".into(),
                category: None,
            },
        ));
    };
    let fields = value.split_whitespace().collect::<Vec<_>>();
    if fields.len() != 3
        || fields
            .iter()
            .any(|s| s.len() != 1 || !s.as_bytes()[0].is_ascii_uppercase())
    {
        return Err(CoreError::InvalidInput(
            "PRIORITIES 必须按最高、最低、默认顺序配置三个大写字母",
        ));
    }
    let high = fields[0].as_bytes()[0];
    let low = fields[1].as_bytes()[0];
    let default = fields[2].as_bytes()[0];
    if high > low || !(high..=low).contains(&default) {
        return Err(CoreError::InvalidInput(
            "PRIORITIES 的优先级范围或默认字母无效",
        ));
    }
    let options: Vec<_> = (high..=low)
        .map(|letter| TaskPriority {
            name: char::from(letter).to_string(),
            category: Some(if letter == high {
                PeriodCategory::Hight
            } else if letter == low {
                PeriodCategory::Low
            } else {
                PeriodCategory::Middle
            }),
        })
        .collect();
    let default = options[(default - high) as usize].clone();
    Ok((options, default))
}

impl OrgFile {
    /// 默认值仅用于有效优先级求值，不代表标题保存了优先级标记。
    pub fn default_priority(&self) -> &TaskPriority {
        &self.default_priority
    }

    pub fn priority_options(&self) -> Vec<TaskPriority> {
        self.priority_options.clone()
    }

    pub(super) fn validate_priority(&self, value: Option<&str>) -> Result<(), CoreError> {
        if let Some(value) = value {
            if value.len() != 1 || !value.as_bytes()[0].is_ascii_uppercase() {
                return Err(CoreError::InvalidInput("优先级必须是单个大写字母"));
            }
            if !self.priority_options.iter().any(|item| item.name == value) {
                return Err(CoreError::InvalidInput("优先级不属于目标文件配置"));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ranges_and_categories_come_from_effective_file_configuration() {
        let file = OrgFile::with_todo_defaults_and_setup(
            "repo".into(),
            "a.org".into(),
            b"#+PRIORITIES: B F D\n* TODO [#Z] Legacy\n* TODO Unset\n".to_vec(),
            super::super::TodoConfig::default(),
            "#+PRIORITIES: A C B\n".into(),
        )
        .unwrap();
        let expected = [
            PeriodCategory::Hight,
            PeriodCategory::Middle,
            PeriodCategory::Middle,
            PeriodCategory::Middle,
            PeriodCategory::Low,
        ];
        assert_eq!(
            file.priority_options()
                .iter()
                .map(|p| p.category.unwrap())
                .collect::<Vec<_>>(),
            expected
        );
        let tasks = file.nodes();
        assert_eq!(tasks[0].priority().unwrap().name, "Z");
        assert_eq!(tasks[0].priority().unwrap().category, None);
        assert_eq!(
            tasks[0]
                .task_priority_of(PeriodCategory::Hight)
                .unwrap()
                .name,
            "B"
        );
        assert_eq!(
            tasks[0]
                .task_priority_of(PeriodCategory::Middle)
                .unwrap()
                .name,
            "C"
        );
        assert_eq!(
            tasks[0].task_priority_of(PeriodCategory::Low).unwrap().name,
            "F"
        );
        assert!(tasks[1].priority().is_none());
        assert_eq!(
            tasks[0].priority_options(),
            tasks[0].file_metadata().priority_options()
        );
        assert_eq!(file.clone().priority_options(), file.priority_options());
        assert_eq!(file.default_priority().name, "D");
    }
    #[test]
    fn unconfigured_and_literal_keywords_do_not_create_candidates() {
        for source in [
            "* TODO [#A] Existing\n",
            "#+begin_src org\n#+PRIORITIES: A C B\n#+end_src\n* TODO Task\n",
            "* Heading\n#+PRIORITIES: A C B\n",
        ] {
            let file =
                OrgFile::new("repo".into(), "a.org".into(), source.as_bytes().to_vec()).unwrap();
            assert!(file.priority_options().is_empty());
            assert_eq!(file.default_priority().name, "B");
            assert_eq!(file.nodes()[0].default_priority().name, "B");
            assert_eq!(file.source_bytes(), source.as_bytes());
        }
        for value in ["a C B", "A C", "A C Z", "Z A B", "1 3 2", "A C B D"] {
            assert!(
                OrgFile::new(
                    "repo".into(),
                    "a.org".into(),
                    format!("#+PRIORITIES: {value}\n").into_bytes()
                )
                .is_err()
            );
        }
    }
    #[test]
    fn trigger_cycles_use_configured_boundaries_and_default_letter() {
        for (initial, action, expected) in [
            ("", "up", Some("C")),
            ("[#B] ", "up", None),
            ("[#D] ", "down", None),
            ("[#C] ", "up", Some("B")),
            ("[#C] ", "down", Some("D")),
        ] {
            let source = format!(
                "#+PRIORITIES: B D C\n* TODO Source\n:PROPERTIES:\n:TRIGGER: next-sibling set-priority!({action})\n:END:\n* TODO {initial}Target\n"
            );
            let mut file =
                OrgFile::new("repo".into(), "a.org".into(), source.into_bytes()).unwrap();
            let headline = file.path_headlines()[0].1.clone();
            super::super::task_state::modify_at(
                &mut file,
                &headline,
                Some("DONE"),
                chrono::Local::now().naive_local(),
            )
            .unwrap();
            assert_eq!(
                file.nodes()[1].priority().map(|p| p.name.as_str()),
                expected
            );
        }
    }

    #[test]
    fn one_or_two_candidates_and_serialization_keep_category_names() {
        for (value, categories) in [
            ("Q Q Q", vec![PeriodCategory::Hight]),
            ("M N M", vec![PeriodCategory::Hight, PeriodCategory::Low]),
        ] {
            let file = OrgFile::new(
                "repo".into(),
                "a.org".into(),
                format!("#+PRIORITIES: {value}\n* TODO Task\n").into_bytes(),
            )
            .unwrap();
            let task = file.nodes().remove(0);
            assert_eq!(
                task.priority_options()
                    .iter()
                    .map(|p| p.category.unwrap())
                    .collect::<Vec<_>>(),
                categories
            );
            assert!(task.task_priority_of(PeriodCategory::Middle).is_none());
            assert!(task.priority().is_none());
        }
        assert_eq!(
            serde_json::to_string(&PeriodCategory::Hight).unwrap(),
            "\"Hight\""
        );
    }
}
