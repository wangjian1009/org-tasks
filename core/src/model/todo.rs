//! TODO 文内设置与全局默认值；声明和来源范围只从 orgize CST 读取。
use super::{SourceRange, editor::position_at};
use crate::CoreError;
use orgize::{ParseConfig, ast::Keyword, rowan::ast::AstNode};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TodoSource {
    GlobalDefault,
    InBuffer,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TodoWorkflowKind {
    Sequence,
    Type,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TodoStateKind {
    Pending,
    Done,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TodoLogAction {
    Time,
    Note,
}

/// 与 org-todo-keywords 一致，keywords 保留分隔符和括号后缀。
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TodoWorkflowSpec {
    pub kind: TodoWorkflowKind,
    pub keywords: Vec<String>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TodoConfig {
    pub workflows: Vec<TodoWorkflowSpec>,
}
impl Default for TodoConfig {
    fn default() -> Self {
        Self {
            workflows: vec![TodoWorkflowSpec {
                kind: TodoWorkflowKind::Sequence,
                keywords: vec!["TODO".into(), "|".into(), "DONE".into()],
            }],
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TodoDeclaration {
    pub keyword: String,
    pub value: String,
    pub range: SourceRange,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TodoStateMetadata {
    pub name: String,
    pub kind: TodoStateKind,
    pub fast_key: Option<char>,
    pub enter_log: Option<TodoLogAction>,
    pub leave_log: Option<TodoLogAction>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TodoWorkflow {
    pub kind: TodoWorkflowKind,
    pub states: Vec<TodoStateMetadata>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TodoMetadata {
    pub source: TodoSource,
    pub declarations: Vec<TodoDeclaration>,
    pub workflows: Vec<TodoWorkflow>,
    pub pending_keywords: Vec<String>,
    pub done_keywords: Vec<String>,
    pub initial_state: Option<String>,
}

fn declarations(source: &str, syntax: &orgize::Org) -> Vec<TodoDeclaration> {
    syntax
        .document()
        .syntax()
        .descendants()
        .filter_map(Keyword::cast)
        .filter_map(|node| {
            let keyword = node.key().to_ascii_uppercase();
            if !matches!(keyword.as_str(), "TODO" | "SEQ_TODO" | "TYP_TODO") {
                return None;
            }
            Some(TodoDeclaration {
                keyword,
                value: node.value().trim().into(),
                range: SourceRange {
                    start: position_at(source.as_bytes(), u32::from(node.start()) as usize),
                    end: position_at(source.as_bytes(), u32::from(node.end()) as usize),
                },
            })
        })
        .collect()
}

fn specs(declarations: &[TodoDeclaration]) -> Vec<TodoWorkflowSpec> {
    // Emacs 汇集设置时依次处理 TYP_TODO、TODO、SEQ_TODO；同类保持出现顺序。
    ["TYP_TODO", "TODO", "SEQ_TODO"]
        .into_iter()
        .flat_map(|key| {
            declarations
                .iter()
                .filter(move |item| item.keyword == key)
                .map(move |item| TodoWorkflowSpec {
                    kind: if key == "TYP_TODO" {
                        TodoWorkflowKind::Type
                    } else {
                        TodoWorkflowKind::Sequence
                    },
                    keywords: item.value.split_whitespace().map(String::from).collect(),
                })
        })
        .collect()
}

impl TodoConfig {
    /// 外部设置界面可从 Default 获取默认值，并用原生 Org 声明文本编辑。
    pub fn to_settings(&self) -> String {
        self.workflows
            .iter()
            .map(|flow| {
                format!(
                    "#+{}: {}",
                    if flow.kind == TodoWorkflowKind::Type {
                        "TYP_TODO"
                    } else {
                        "TODO"
                    },
                    flow.keywords.join(" ")
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// 设置编辑器使用原生 Org 声明；空白输入表示清空全局 TODO 识别。
    pub fn from_settings(settings: &str) -> Result<Self, CoreError> {
        let syntax = orgize::Org::parse(settings);
        let items = declarations(settings, &syntax);
        let mut remainder = settings.as_bytes().to_vec();
        for item in &items {
            for byte in &mut remainder
                [item.range.start.byte_offset as usize..item.range.end.byte_offset as usize]
            {
                *byte = b' ';
            }
        }
        if remainder.iter().any(|byte| !byte.is_ascii_whitespace()) {
            return Err(CoreError::InvalidInput(
                "TODO 默认设置只允许 TODO、SEQ_TODO、TYP_TODO 声明",
            ));
        }
        let config = Self {
            workflows: specs(&items),
        };
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), CoreError> {
        self.metadata(TodoSource::GlobalDefault, Vec::new())
            .map(|_| ())
    }

    fn metadata(
        &self,
        source: TodoSource,
        declarations: Vec<TodoDeclaration>,
    ) -> Result<TodoMetadata, CoreError> {
        let mut workflows = Vec::new();
        let mut done_keywords = Vec::new();
        for spec in &self.workflows {
            let mut states = Vec::new();
            let mut done = false;
            let has_separator = spec.keywords.iter().any(|word| word == "|");
            for word in &spec.keywords {
                if word == "|" {
                    if done {
                        return Err(CoreError::InvalidInput("每条 TODO 流程只能有一个分隔符 |"));
                    }
                    done = true;
                    continue;
                }
                let mut state = parse_state(word)?;
                state.kind = if done {
                    TodoStateKind::Done
                } else {
                    TodoStateKind::Pending
                };
                states.push(state);
            }
            if !has_separator {
                if let Some(last) = states.last_mut() {
                    last.kind = TodoStateKind::Done;
                }
            }
            for state in &states {
                if state.kind == TodoStateKind::Done && !done_keywords.contains(&state.name) {
                    done_keywords.push(state.name.clone());
                }
            }
            workflows.push(TodoWorkflow {
                kind: spec.kind,
                states,
            });
        }
        // 与 Emacs 一致：全部流程都没给出完成状态时，最后一个关键词仍作为完成状态。
        if done_keywords.is_empty() {
            if let Some(last) = workflows.iter().rev().find_map(|flow| flow.states.last()) {
                done_keywords.push(last.name.clone());
            }
        }
        let mut pending_keywords = Vec::new();
        for flow in &mut workflows {
            for state in &mut flow.states {
                if done_keywords.contains(&state.name) {
                    state.kind = TodoStateKind::Done;
                } else if !pending_keywords.contains(&state.name) {
                    pending_keywords.push(state.name.clone());
                }
            }
        }
        Ok(TodoMetadata {
            source,
            declarations,
            workflows,
            initial_state: pending_keywords.first().cloned(),
            pending_keywords,
            done_keywords,
        })
    }
}

impl TodoMetadata {
    pub(crate) fn parse_with_setup(
        source: &str,
        defaults: &TodoConfig,
        setup_settings: &str,
    ) -> Result<(Self, orgize::Org), CoreError> {
        let initial = orgize::Org::parse(source);
        let local_declarations = declarations(source, &initial);
        let setup_syntax = orgize::Org::parse(setup_settings);
        let setup_declarations = declarations(setup_settings, &setup_syntax);
        let metadata = if local_declarations.is_empty() && !setup_declarations.is_empty() {
            TodoConfig { workflows: specs(&setup_declarations) }
                .metadata(TodoSource::InBuffer, Vec::new())?
        } else if local_declarations.is_empty() {
            defaults.metadata(TodoSource::GlobalDefault, local_declarations)?
        } else {
            TodoConfig {
                workflows: specs(&local_declarations),
            }
            .metadata(TodoSource::InBuffer, local_declarations)?
        };
        let syntax = ParseConfig {
            todo_keywords: (
                metadata.pending_keywords.clone(),
                metadata.done_keywords.clone(),
            ),
            ..ParseConfig::default()
        }
        .parse(source);
        Ok((metadata, syntax))
    }
}

pub(super) fn parse_state(word: &str) -> Result<TodoStateMetadata, CoreError> {
    let (name, suffix) = if let Some((name, rest)) = word.split_once('(') {
        (
            name,
            Some(
                rest.strip_suffix(')')
                    .ok_or(CoreError::InvalidInput("TODO 关键词的括号后缀不完整"))?,
            ),
        )
    } else {
        (word, None)
    };
    if name.is_empty()
        || name
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || matches!(c, '|' | '(' | ')'))
    {
        return Err(CoreError::InvalidInput(
            "TODO 关键词不能为空或包含空白、分隔符与括号",
        ));
    }
    let mut state = TodoStateMetadata {
        name: name.into(),
        kind: TodoStateKind::Pending,
        fast_key: None,
        enter_log: None,
        leave_log: None,
    };
    if let Some(suffix) = suffix {
        let mut chars = suffix.chars().peekable();
        if chars.peek().is_some_and(|c| !matches!(*c, '!' | '@' | '/')) {
            state.fast_key = chars.next();
        }
        let rest = chars.collect::<String>();
        let (enter, leave) = rest
            .split_once('/')
            .map(|(a, b)| (a, Some(b)))
            .unwrap_or((&rest, None));
        fn log(value: &str) -> Result<Option<TodoLogAction>, CoreError> {
            match value {
                "" => Ok(None),
                "!" => Ok(Some(TodoLogAction::Time)),
                "@" => Ok(Some(TodoLogAction::Note)),
                _ => Err(CoreError::InvalidInput(
                    "TODO 日志后缀只允许 !、@ 和 / 分隔",
                )),
            }
        }
        state.enter_log = log(enter)?;
        state.leave_log = leave.map(log).transpose()?.flatten();
    }
    Ok(state)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{OrgFile, OrgRepo, OrgWorkspace};

    fn file(source: &str) -> OrgFile {
        OrgFile::with_todo_defaults(
            "repo".into(),
            "inbox.org".into(),
            source.as_bytes().to_vec(),
            TodoConfig::from_settings("#+TODO: GLOBAL(g) | CLOSED(c)").unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn defaults_are_provided_by_rust_and_file_declarations_replace_them() {
        assert_eq!(TodoConfig::default().to_settings(), "#+TODO: TODO | DONE");
        let default = file("* GLOBAL Task\n* CLOSED End\n* TODO Plain\n");
        assert_eq!(default.todo.source, TodoSource::GlobalDefault);
        assert_eq!(default.todo.initial_state.as_deref(), Some("GLOBAL"));
        let source = "#+TODO: OPEN(o) WAIT(w@/!) | FINISHED(f!) CANCELLED(c@)\n* OPEN Task\n* FINISHED Done\n* GLOBAL Plain\n";
        let file = file(source);
        assert_eq!(file.todo.source, TodoSource::InBuffer);
        assert_eq!(file.todo.pending_keywords, ["OPEN", "WAIT"]);
        assert_eq!(file.todo.done_keywords, ["FINISHED", "CANCELLED"]);
        let wait = &file.todo.workflows[0].states[1];
        assert_eq!(
            (wait.fast_key, wait.enter_log, wait.leave_log),
            (
                Some('w'),
                Some(TodoLogAction::Note),
                Some(TodoLogAction::Time)
            )
        );
        let decl = &file.todo.declarations[0];
        assert_eq!(
            &file.source_bytes()
                [decl.range.start.byte_offset as usize..decl.range.end.byte_offset as usize],
            source
                .lines()
                .next()
                .unwrap()
                .to_string()
                .as_bytes()
                .iter()
                .copied()
                .chain([b'\n'])
                .collect::<Vec<_>>()
        );
        assert_eq!(file.source_bytes(), source.as_bytes());
    }

    #[test]
    fn emacs_separator_rules_parallel_workflows_and_case_are_preserved() {
        let f = file("#+SEQ_TODO: A B C\n");
        assert_eq!(f.todo.pending_keywords, ["A", "B"]);
        assert_eq!(f.todo.done_keywords, ["C"]);
        let f = file("#+SEQ_TODO: S1 | S2\n#+TODO: T1 | T2\n#+TYP_TODO: P1 P2 | P3\n");
        assert_eq!(f.todo.pending_keywords, ["P1", "P2", "T1", "S1"]);
        assert_eq!(f.todo.workflows[0].kind, TodoWorkflowKind::Type);
        let f = file("  #+todo: lower | done\n");
        assert_eq!(f.todo.pending_keywords, ["lower"]);
        assert_eq!(f.todo.done_keywords, ["done"]);
        let f = file("#+TODO: A B |\n");
        assert_eq!(f.todo.done_keywords, ["B"]);
        let f = file("#+TODO: A B |\n#+TODO: X | Y\n");
        assert_eq!(f.todo.pending_keywords, ["A", "B", "X"]);
        let f = file(
            "#+TODO: TODO(t) | DONE(d)\n#+TODO: REVIEW(r) VERIFY(v) | ACCEPTED(a)\n#+TODO: | CANCELED(c)\n",
        );
        assert_eq!(f.todo.done_keywords, ["DONE", "ACCEPTED", "CANCELED"]);
        assert_eq!(f.todo.pending_keywords, ["TODO", "REVIEW", "VERIFY"]);
    }

    #[test]
    fn file_level_cancel_state_is_projected_as_done() {
        let f = file("#+TODO: TODO | DONE CNCL\n* CNCL Cancelled\n");
        let headline = f
            .syntax()
            .document()
            .syntax()
            .descendants()
            .filter_map(orgize::ast::Headline::cast)
            .next()
            .unwrap();
        assert_eq!(headline.todo_keyword().map(|value| value.to_string()), Some("CNCL".into()));
        assert_eq!(headline.todo_type(), Some(orgize::ast::TodoType::Done));
    }

    #[test]
    fn empty_declaration_disables_todo_and_blocks_do_not_override_defaults() {
        let f = file("#+TODO:\n* GLOBAL Plain\n");
        assert_eq!(f.todo.source, TodoSource::InBuffer);
        assert!(f.todo.pending_keywords.is_empty() && f.todo.done_keywords.is_empty());
        let f = file(
            "#+begin_src org\n#+TODO: BAD | BAD_DONE\n#+end_src\n#+begin_example\n#+TODO: HIDDEN | HIDDEN_DONE\n#+end_example\n* GLOBAL Real\n",
        );
        assert_eq!(f.todo.source, TodoSource::GlobalDefault);
        assert_eq!(f.todo.pending_keywords, ["GLOBAL"]);
        assert!(TodoConfig::from_settings("#+TODO: BAD(w??) | END").is_err());
        assert!(TodoConfig::from_settings("* Invalid heading").is_err());
        assert!(TodoConfig::from_settings("").unwrap().workflows.is_empty());
    }

    #[tokio::test]
    async fn declaration_after_headlines_applies_to_entire_file_and_done_filter_uses_it() {
        let f = file(
            "* OPEN Before\n#+TODO: OPEN | FINISHED CANCELED\n* FINISHED End\n* TODO Plain\n* CANCELED Cancelled\n",
        );
        let mut repo = OrgRepo::new("/tmp/todo".into()).unwrap();
        repo.id = "repo".into();
        { let value = vec![f]; crate::model::test_support::write_files(&mut repo, value); }
        let workspace = OrgWorkspace::new(vec![repo]).unwrap();
        let done = workspace.query(&crate::TaskQuery { expression: "it.done".into(), ..Default::default() }).await.unwrap().tasks;
        assert_eq!(
            done.iter()
                .map(|task| task.state.as_deref().unwrap())
                .collect::<Vec<_>>(),
            ["FINISHED", "CANCELED"]
        );
        let pending = workspace.query(&crate::TaskQuery { expression: "it.todo".into(), ..Default::default() }).await.unwrap().tasks;
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].title, "Before");
    }

    #[test]
    fn clones_and_reparsing_preserve_global_defaults_and_only_change_target_bytes() {
        use crate::{OrgFileEdit, SourcePosition, apply_edit};
        let mut f = file("* GLOBAL Task\r\n  body  \r\n");
        let original = f.source_bytes().to_vec();
        assert_eq!(f.clone().todo, f.todo);
        apply_edit(
            &mut f,
            OrgFileEdit::InsertAt {
                anchor: SourcePosition::new(1, 0, 0).unwrap(),
                content: b"#+TODO: OPEN | FINISHED\r\n".to_vec(),
            },
        )
        .unwrap();
        assert!(f.source_bytes().ends_with(&original));
        assert_eq!(f.todo.source, TodoSource::InBuffer);
        assert_eq!(f.todo.initial_state.as_deref(), Some("OPEN"));
        let before = f.clone();
        assert!(
            apply_edit(
                &mut f,
                OrgFileEdit::InsertAt {
                    anchor: SourcePosition::new(1, 0, 0).unwrap(),
                    content: b"#+TODO: BAD(??) | END\n".to_vec()
                }
            )
            .is_err()
        );
        assert_eq!(f, before);
    }
    #[tokio::test]
    async fn matches_emacs_org_element_oracle() {
        let cases: Vec<serde_json::Value> =
            serde_json::from_str(include_str!("../../tests/data/todo_emacs.json")).unwrap();
        for case in cases {
            let source = case["source"].as_str().unwrap();
            let defaults = TodoConfig::from_settings(case["defaults"].as_str().unwrap()).unwrap();
            let file = OrgFile::with_todo_defaults(
                "repo".into(),
                "oracle.org".into(),
                source.as_bytes().to_vec(),
                defaults,
            )
            .unwrap();
            assert_eq!(
                serde_json::json!(file.todo.pending_keywords),
                case["pending"],
                "{source}"
            );
            assert_eq!(
                serde_json::json!(file.todo.done_keywords),
                case["done"],
                "{source}"
            );
            assert_eq!(
                serde_json::json!(
                    file.todo
                        .workflows
                        .iter()
                        .map(|flow| flow
                            .states
                            .iter()
                            .map(|state| state.name.as_str())
                            .collect::<Vec<_>>())
                        .collect::<Vec<_>>()
                ),
                case["groups"],
                "{source}"
            );
            let mut repo = OrgRepo::new("/tmp/oracle".into()).unwrap();
            repo.id = "repo".into();
            repo.todo_defaults = file.todo_defaults.clone();
            { let value = file.clone(); crate::model::test_support::push_file(&mut repo, value); };
            let actual = OrgWorkspace::new(vec![repo])
                .unwrap()
                .query(&crate::TaskQuery::default()).await.unwrap().tasks;
            let headlines = actual.iter().map(|task| serde_json::json!({ "title": task.title, "state": task.state,
                "kind": match task.state_type { crate::FilterStateType::Todo => Some("pending"), crate::FilterStateType::Done => Some("done"), _ => None },
            })).collect::<Vec<_>>();
            assert_eq!(serde_json::json!(headlines), case["headlines"], "{source}");
            assert_eq!(file.source_bytes(), source.as_bytes());
        }
    }
    #[test]
    fn task_merge_uses_the_same_external_defaults_as_file_parsing() {
        let local = file("* GLOBAL Same\n* GLOBAL Changed\nlocal\n");
        let remote = file("* GLOBAL Same\n* GLOBAL Changed\nremote\n");
        let plan = crate::compare_org_tasks(&local, &remote, None);
        let choices = plan
            .items
            .iter()
            .filter(|item| item.change != crate::OrgMergeChange::Unchanged)
            .map(|item| crate::OrgMergeChoice {
                key: item.key.clone(),
                side: crate::OrgMergeSide::Local,
            })
            .collect::<Vec<_>>();
        assert_eq!(
            crate::merge_org_tasks(&plan, &choices).unwrap(),
            local.source_bytes()
        );
    }
}
