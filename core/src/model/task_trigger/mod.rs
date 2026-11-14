//! Org Edna 1.1.2 的文件内 TRIGGER 解释器；与重复调度共用 Core 写入事务。
//! 不执行 Lisp，不读取其他文件；宿主相关及未知动作按约定静默跳过。
mod matching;
mod syntax;
mod time;
use super::task_operation_executor::{end, replace, start};
use super::task_state::{metadata_node, property};
use super::{CoreError as Error, OrgFile, TaskModification};
use chrono::NaiveDateTime;
use orgize::{
    ast::{Headline, Timestamp},
    rowan::ast::AstNode,
};
use syntax::{Call, Form, Value};
type Result<T> = std::result::Result<T, Error>;
fn error(message: &'static str) -> Error {
    Error::InvalidInput(message)
}

pub(super) fn modify_at(
    file: &mut OrgFile,
    headline: &Headline,
    value: Option<&str>,
    now: NaiveDateTime,
) -> Result<()> {
    let ordinal = file
        .path_headlines()
        .iter()
        .position(|(_, node)| start(node) == start(headline))
        .ok_or(error("TRIGGER 来源标题不存在"))?;
    Context {
        file,
        now,
        utc_offset: chrono::Local::now().offset().local_minus_utc(),
        steps: 0,
        stack: Vec::new(),
    }
    .todo(ordinal, value)
}
struct Context<'a> {
    file: &'a mut OrgFile,
    now: NaiveDateTime,
    utc_offset: i32,
    steps: usize,
    stack: Vec<usize>,
}
impl Context<'_> {
    fn node(&self, index: usize) -> Result<Headline> {
        let node = self
            .file
            .path_headlines()
            .into_iter()
            .nth(index)
            .ok_or(error("TRIGGER 目标标题不存在"))?
            .1;
        if OrgFile::is_conflict_headline(&node) {
            return Err(error("TRIGGER 不能修改冲突节点"));
        }
        Ok(node)
    }
    fn prop(&self, index: usize, name: &str) -> Result<Option<String>> {
        let node = self.node(index)?;
        Ok(match name.to_ascii_uppercase().as_str() {
            "TODO" => node.todo_keyword().map(|v| v.to_string()),
            "ITEM" => Some(node.title_raw().trim().into()),
            "TAGS" => {
                let tags = node.tags().map(|tag| tag.to_string()).collect::<Vec<_>>();
                (!tags.is_empty()).then(|| format!(":{}:", tags.join(":")))
            }
            "PRIORITY" => Some(node.priority().map(|v| v.to_string()).unwrap_or_else(|| self.file.default_priority().name.clone())),
            "SCHEDULED" => super::task_repeat::planning_timestamp(
                self.file,
                &node,
                orgize::SyntaxKind::PLANNING_SCHEDULED,
            ),
            "DEADLINE" => super::task_repeat::planning_timestamp(
                self.file,
                &node,
                orgize::SyntaxKind::PLANNING_DEADLINE,
            ),
            "TIMESTAMP" => node
                .syntax()
                .descendants()
                .filter_map(Timestamp::cast)
                .find(|ts| {
                    ts.is_active()
                        && ts.syntax().ancestors().all(|node| {
                            !matches!(
                                node.kind(),
                                orgize::SyntaxKind::PLANNING_SCHEDULED
                                    | orgize::SyntaxKind::PLANNING_DEADLINE
                                    | orgize::SyntaxKind::PLANNING_CLOSED
                            )
                        })
                        && ts
                            .syntax()
                            .ancestors()
                            .filter_map(Headline::cast)
                            .next()
                            .is_some_and(|parent| start(&parent) == start(&node))
                })
                .map(|ts| ts.raw()),
            _ => super::properties::own(&metadata_node(self.file, &node), name)
                .filter(|value| value != "nil"),
        })
    }
    fn own_tags(&self, index: usize) -> Result<Vec<String>> {
        Ok(self.node(index)?.tags().map(|t| t.to_string()).collect())
    }
    fn todo(&mut self, index: usize, state: Option<&str>) -> Result<()> {
        let node = self.node(index)?;
        let previous = node.todo_keyword().map(|value| value.to_string());
        let pending = node.todo_keyword().is_some_and(|old| {
            self.file
                .todo
                .category(old.as_ref())
                .is_some_and(|category| !category.is_done())
        });
        let completed = state.is_some_and(|s| self.file.todo.is_done(s));
        super::task_state::modify_without_triggers(self.file, &node, state, self.now)?;
        let updated = self.node(index)?;
        let current = updated.todo_keyword().map(|value| value.to_string());
        if (previous != current || completed)
            && !current
                .as_deref()
                .is_some_and(|s| self.file.todo.is_done(s))
            && (previous.is_some() || current.is_some())
        {
            self.reopen_ancestors(index)?;
        }
        // 与 org-trigger-hook 一致，依据本次请求的状态，而不是重复恢复后的状态判断。
        if pending && completed {
            if let Some(trigger) = self
                .prop(index, "TRIGGER")?
                .filter(|s| !s.trim().is_empty())
            {
                if self.stack.contains(&index) || self.stack.len() >= 32 {
                    return Err(error("TRIGGER 出现循环联动"));
                }
                let forms = syntax::parse(&trigger)?;
                self.stack.push(index);
                self.eval(&forms, index, &[], None, false)?;
                self.stack.pop();
            }
        }
        let node = self.node(index)?;
        for (range, value) in super::title_statistics::parent_edits(self.file, &node)
            .into_iter()
            .rev()
        {
            replace(self.file, range, value.as_bytes())?;
        }
        Ok(())
    }
    fn reopen_ancestors(&mut self, index: usize) -> Result<()> {
        // 标题序号在状态、日志与统计改写期间稳定，不能沿用祖先修改前的字节偏移。
        let nodes = self.file.path_headlines();
        let ancestors = self
            .node(index)?
            .syntax()
            .ancestors()
            .skip(1)
            .filter_map(Headline::cast)
            .filter_map(|ancestor| {
                nodes
                    .iter()
                    .position(|(_, node)| start(node) == start(&ancestor))
            })
            .collect::<Vec<_>>();
        for ancestor in ancestors {
            let node = self.node(ancestor)?;
            let Some(previous) = node
                .todo_keyword()
                .filter(|s| self.file.todo.is_done(s.as_ref()))
            else {
                continue;
            };
            let state = self
                .file
                .todo
                .workflows
                .iter()
                .find(|flow| flow.states.iter().any(|s| s.name == previous.as_ref()))
                .and_then(|flow| {
                    flow.states
                        .iter()
                        .find(|s| s.category == Some(super::TaskStateCategory::Todo))
                        .or_else(|| {
                            flow.states
                                .iter()
                                .find(|s| !self.file.todo.is_done(&s.name))
                        })
                })
                .map(|s| s.name.clone())
                .or_else(|| self.file.todo.initial_state.clone())
                .ok_or(error("父任务没有可用的未完成状态"))?;
            super::task_state::modify_without_triggers(self.file, &node, Some(&state), self.now)?;
            let node = self.node(ancestor)?;
            for (range, value) in super::title_statistics::parent_edits(self.file, &node)
                .into_iter()
                .rev()
            {
                replace(self.file, range, value.as_bytes())?;
            }
        }
        Ok(())
    }
    fn eval(
        &mut self,
        forms: &[Form],
        source: usize,
        inherited: &[usize],
        inherited_consideration: Option<&Value>,
        condition: bool,
    ) -> Result<Option<bool>> {
        let mut targets = inherited.to_vec();
        let initial_consideration = inherited_consideration
            .cloned()
            .unwrap_or(Value::Symbol("any".into()));
        let mut consideration = initial_consideration.clone();
        let mut executed = false;
        let mut found = false;
        let mut blocked = false;
        for form in forms {
            self.steps += 1;
            if self.steps > 4096 {
                return Err(error("TRIGGER 执行次数超出限制"));
            }
            match form {
                Form::If(test, yes, no) => {
                    if let Some(block) = self.eval(test, source, &[], None, true)? {
                        let branch = if block { no } else { yes };
                        if let Some(value) =
                            self.eval(branch, source, &targets, Some(&consideration), condition)?
                        {
                            blocked |= value;
                        }
                    }
                }
                Form::Call(call) => {
                    let name = call.name.trim_start_matches('!');
                    if name == "consider" || name == "consideration" {
                        consideration = call
                            .args
                            .first()
                            .cloned()
                            .unwrap_or(Value::Symbol("any".into()));
                    } else if name.ends_with('!') {
                        // 未支持动作不解析参数、不生成修改，也不阻止其后的动作。
                        for target in targets.clone() {
                            self.steps += 1;
                            if self.steps > 4096 {
                                return Err(error("TRIGGER 执行次数超出限制"));
                            }
                            self.action(call, source, target)?;
                        }
                        executed = true;
                    } else if name.ends_with('?') {
                        if !blocked {
                            let values = targets
                                .iter()
                                .map(|target| self.condition(call, *target))
                                .collect::<Result<Vec<_>>>()?;
                            if values.iter().any(Option::is_none) {
                                return Ok(None);
                            }
                            blocked |= consider(
                                &consideration,
                                &values.into_iter().flatten().collect::<Vec<_>>(),
                            )?;
                        }
                        executed = true;
                    } else {
                        // 新查找出现在动作/条件后时开启新作用域，保留 if 分支的外层目标。
                        if executed {
                            targets = inherited.to_vec();
                            consideration = initial_consideration.clone();
                            executed = false;
                        }
                        for target in self.find(call, source)? {
                            if !targets.contains(&target) {
                                targets.push(target);
                            }
                        }
                        found = true;
                    }
                }
            }
        }
        // Edna 条件只写 finder 时，默认使用 !done?。
        if condition && found && !executed && !blocked {
            let values = targets
                .iter()
                .map(|target| {
                    self.condition(
                        &Call {
                            name: "!done?".into(),
                            args: Vec::new(),
                        },
                        *target,
                    )
                })
                .collect::<Result<Vec<_>>>()?
                .into_iter()
                .flatten()
                .collect::<Vec<_>>();
            blocked |= consider(&consideration, &values)?;
        }
        Ok(Some(blocked))
    }
    fn find(&self, call: &Call, source: usize) -> Result<Vec<usize>> {
        let args = &call.args;
        match call.name.trim_start_matches('!') {
            "self" => Ok(vec![source]),
            "ids" => {
                let mut targets = Vec::new();
                for id in args {
                    let id = id.text()?.strip_prefix("id:").unwrap_or(id.text()?);
                    let matches = self
                        .file
                        .path_headlines()
                        .iter()
                        .enumerate()
                        .filter_map(|(i, _)| {
                            (self.prop(i, "ID").ok().flatten().as_deref() == Some(id)).then_some(i)
                        })
                        .collect::<Vec<_>>();
                    if matches.len() > 1 {
                        return Err(error("TRIGGER 目标 ID 在本文件中不唯一"));
                    }
                    targets.extend(matches);
                }
                Ok(targets)
            }
            "file" | "org-file" => Ok(Vec::new()),
            "olp" => {
                if arg(args, 0)? != self.file.path {
                    return Ok(Vec::new());
                }
                let path = arg(args, 1)?.split('/').collect::<Vec<_>>();
                Ok(self
                    .file
                    .path_headlines()
                    .iter()
                    .enumerate()
                    .filter_map(|(i, (p, _))| {
                        (p.titles.iter().map(String::as_str).collect::<Vec<_>>() == path)
                            .then_some(i)
                    })
                    .collect())
            }
            "match" => {
                let spec = arg(args, 0)?;
                let scope = args
                    .get(1)
                    .map(Value::text)
                    .transpose()?
                    .unwrap_or("buffer");
                if !["nil", "buffer", "file", "tree"].contains(&scope) {
                    return Ok(Vec::new());
                }
                // Lisp skip 函数不能执行；显式指定时跳过此查找。
                if args.get(2).is_some_and(|v| v.symbol() != Some("nil")) {
                    return Ok(Vec::new());
                }
                let node = self.node(source)?;
                let mut targets = Vec::new();
                for (i, (_, target)) in self.file.path_headlines().iter().enumerate() {
                    if scope == "tree"
                        && !(start(target) >= start(&node) && start(target) < end(&node))
                    {
                        continue;
                    }
                    if self.matches(i, spec)? {
                        targets.push(i);
                    }
                }
                Ok(targets)
            }
            name if syntax::is_finder(name) => self.relatives(name, args, source),
            _ => Ok(Vec::new()),
        }
    }
    fn relatives(&self, name: &str, args: &[Value], source: usize) -> Result<Vec<usize>> {
        let (select, limit) = match name {
            "siblings" => ("from-top", 0),
            "rest-of-siblings" => ("forward-no-wrap", 0),
            "rest-of-siblings-wrap" | "siblings-wrap" => ("forward-wrap", 0),
            "next-sibling" => ("forward-no-wrap", 1),
            "next-sibling-wrap" => ("forward-wrap", 1),
            "previous-sibling" => ("backward-no-wrap", 1),
            "previous-sibling-wrap" => ("backward-wrap", 1),
            "first-child" => ("step-down", 1),
            "children" => ("step-down", 0),
            "parent" => ("walk-up", 1),
            "ancestors" => ("walk-up", 0),
            "descendants" => ("walk-down", 0),
            _ => ("", 0),
        };
        let mut select = select;
        let mut limit = limit;
        let mut sort = "";
        let mut reverse = false;
        for option in args {
            if let Some(n) = option.number() {
                limit = n as i64;
            } else if let Some(s) = option.symbol() {
                if [
                    "from-top",
                    "from-bottom",
                    "from-current",
                    "no-wrap",
                    "forward-no-wrap",
                    "forward-wrap",
                    "backward-no-wrap",
                    "backward-wrap",
                    "walk-up",
                    "walk-up-with-self",
                    "walk-down",
                    "walk-down-with-self",
                    "step-down",
                ]
                .contains(&s)
                {
                    select = s;
                } else if s == "reverse-sort" {
                    reverse = true;
                } else if s == "no-sort" {
                    sort = "";
                    reverse = false;
                } else if s.ends_with("-up") || s.ends_with("-down") || s == "random-sort" {
                    sort = s;
                }
            }
        }
        let nodes = self.file.path_headlines();
        let parent = |index: usize| {
            nodes[..index]
                .iter()
                .rposition(|(_, node)| node.level() < nodes[index].1.level())
        };
        let source_node = &nodes[source].1;
        let siblings = nodes
            .iter()
            .enumerate()
            .filter_map(|(i, (_, node))| {
                (node.level() == source_node.level() && parent(i) == parent(source)).then_some(i)
            })
            .collect::<Vec<_>>();
        let mut targets = match select {
            "from-top" => siblings.clone(),
            "from-bottom" => siblings.iter().rev().copied().collect(),
            "from-current" | "forward-wrap" | "no-wrap" | "forward-no-wrap" | "backward-wrap"
            | "backward-no-wrap" => {
                let at = siblings.iter().position(|i| *i == source).unwrap();
                let backward = select.starts_with("backward");
                let wrap = select.ends_with("wrap") && !select.ends_with("no-wrap")
                    || select == "from-current";
                let mut out = Vec::new();
                for n in 1..siblings.len() {
                    let index = if backward {
                        at as isize - n as isize
                    } else {
                        at as isize + n as isize
                    };
                    if !wrap && (index < 0 || index >= siblings.len() as isize) {
                        break;
                    }
                    out.push(siblings[index.rem_euclid(siblings.len() as isize) as usize]);
                }
                out
            }
            "walk-up" | "walk-up-with-self" => {
                let mut out = Vec::new();
                if select.ends_with("with-self") {
                    out.push(source);
                }
                let mut next = parent(source);
                while let Some(i) = next {
                    out.push(i);
                    next = parent(i);
                }
                out
            }
            "walk-down" | "walk-down-with-self" => nodes
                .iter()
                .enumerate()
                .filter_map(|(i, (_, node))| {
                    ((i > source || (i == source && select.ends_with("with-self")))
                        && start(node) < end(source_node))
                    .then_some(i)
                })
                .collect(),
            "step-down" => nodes
                .iter()
                .enumerate()
                .filter_map(|(i, _)| (parent(i) == Some(source)).then_some(i))
                .collect(),
            _ => Vec::new(),
        };
        if sort == "random-sort" {
            // 不依赖全局随机状态，使用系统随机字节进行 Fisher-Yates 置换。
            for i in (1..targets.len()).rev() {
                let mut bytes = [0; 8];
                getrandom::fill(&mut bytes).map_err(|_| error("随机排序失败"))?;
                targets.swap(i, (u64::from_ne_bytes(bytes) % (i as u64 + 1)) as usize);
            }
        } else if !sort.is_empty() {
            let field = sort.split('-').next().unwrap().to_ascii_uppercase();
            let mut keys = std::collections::BTreeMap::new();
            for i in &targets {
                let value = self.prop(*i, &field)?;
                if field == "EFFORT" && value.is_none() {
                    return Err(error("工作量排序要求目标具有 EFFORT"));
                }
                let key = if field == "EFFORT" {
                    effort(value.as_deref().unwrap())?
                } else if field == "PRIORITY" {
                    f64::from(
                        value
                            .as_deref()
                            .unwrap_or("B")
                            .bytes()
                            .next()
                            .unwrap_or(b'B'),
                    )
                } else {
                    value
                        .as_deref()
                        .map(time::read)
                        .transpose()?
                        .map_or(self.now, |v| v.0)
                        .and_utc()
                        .timestamp() as f64
                };
                keys.insert(*i, key);
            }
            targets.sort_by(|a, b| {
                let cmp = keys[a].total_cmp(&keys[b]);
                if (sort.ends_with("-up") && field != "PRIORITY")
                    || (sort.ends_with("-down") && field == "PRIORITY")
                {
                    cmp.reverse()
                } else {
                    cmp
                }
            });
        }
        for option in args {
            targets = targets
                .into_iter()
                .filter_map(|i| {
                    let keep: Result<bool> = (|| {
                        Ok(match option {
                            Value::String(s) if s.starts_with('+') => {
                                self.own_tags(i)?.iter().any(|tag| tag == &s[1..])
                            }
                            Value::String(s) if s.starts_with('-') => {
                                !self.own_tags(i)?.iter().any(|tag| tag == &s[1..])
                            }
                            Value::String(s) => {
                                matching::regex(s)?.is_match(nodes[i].1.title_raw().trim())
                            }
                            Value::Symbol(s) if s == "todo-only" => {
                                self.prop(i, "TODO")?.is_some_and(|s| {
                                    self.file
                                        .todo
                                        .category(&s)
                                        .is_some_and(|category| !category.is_done())
                                })
                            }
                            Value::Symbol(s) if s == "todo-and-done-only" => {
                                self.prop(i, "TODO")?.is_some()
                            }
                            Value::Symbol(s) if s == "no-comment" || s == "no-comments" => !nodes
                                [i]
                                .1
                                .syntax()
                                .ancestors()
                                .filter_map(Headline::cast)
                                .any(|node| node.is_commented()),
                            Value::Symbol(s) if s == "no-archive" => {
                                !self.own_tags(i)?.iter().any(|tag| tag == "ARCHIVE")
                            }
                            _ => true,
                        })
                    })();
                    match keep {
                        Ok(true) => Some(Ok(i)),
                        Ok(false) => None,
                        Err(e) => Some(Err(e)),
                    }
                })
                .collect::<Result<Vec<_>>>()?;
        }
        if reverse {
            targets.reverse();
        }
        if limit < 0 {
            targets.truncate(targets.len().saturating_sub(limit.unsigned_abs() as usize));
        } else if limit > 0 && limit < targets.len() as i64 {
            targets.truncate(limit as usize);
        }
        Ok(targets)
    }
    fn condition(&self, call: &Call, target: usize) -> Result<Option<bool>> {
        let neg = call.name.starts_with('!');
        let name = call.name.trim_start_matches('!');
        let args = &call.args;
        let result = match name {
            "done?" => {
                let state = self.prop(target, "TODO")?;
                return Ok(Some(state.is_some_and(|s| {
                    if neg {
                        self.file
                            .todo
                            .category(&s)
                            .is_some_and(|category| !category.is_done())
                    } else {
                        self.file.todo.is_done(&s)
                    }
                })));
            }
            "todo-state?" => self.prop(target, "TODO")?.as_deref() == Some(arg(args, 0)?),
            "headings?" => !self.file.path_headlines().is_empty(),
            "has-property?" => self.prop(target, arg(args, 0)?)?.as_deref() == Some(arg(args, 1)?),
            "has-tags?" => {
                let tags = self.own_tags(target)?;
                args.iter()
                    .map(Value::text)
                    .collect::<Result<Vec<_>>>()?
                    .iter()
                    .any(|tag| tags.iter().any(|own| own == tag))
            }
            "re-search?" => matching::regex(arg(args, 0)?)?.is_match(
                std::str::from_utf8(&self.file.source_bytes()[start(&self.node(target)?)..])
                    .unwrap(),
            ),
            "matches?" => self.matches(target, arg(args, 0)?)?,
            _ => return Ok(None),
        };
        Ok(Some(result ^ neg))
    }
    fn action(&mut self, call: &Call, source: usize, target: usize) -> Result<()> {
        let args = &call.args;
        match call.name.trim_start_matches('!') {
            "todo!" => {
                let state = arg(args, 0)?;
                self.todo(target, (!state.is_empty()).then_some(state))?;
            }
            "scheduled!" | "deadline!" => {
                let kind = if call.name == "scheduled!" {
                    orgize::SyntaxKind::PLANNING_SCHEDULED
                } else {
                    orgize::SyntaxKind::PLANNING_DEADLINE
                };
                if !time::supports(arg(args, 0)?) {
                    return Ok(());
                }
                let old =
                    super::task_repeat::planning_timestamp(self.file, &self.node(target)?, kind);
                let last =
                    super::task_repeat::planning_timestamp(self.file, &self.node(source)?, kind);
                let format = self.prop(target, "EDNA_TS_FORMAT")?;
                let value = time::plan(
                    arg(args, 0)?,
                    old.as_deref(),
                    last.as_deref(),
                    format.as_deref(),
                    self.now,
                    self.utc_offset,
                )?;
                // Org 的日期设置保留目标已有重复器和预警；copy 直接复制日期与时刻。
                let mut value = value;
                if !["cp", "copy"].contains(&arg(args, 0)?) {
                    if let (Some(value), Some(old)) = (&mut value, old.as_deref()) {
                        for modifier in old.trim_end_matches('>').split_whitespace().filter(|s| {
                            s.starts_with('+') || s.starts_with(".+") || s.starts_with('-')
                        }) {
                            let is_repeat = modifier.starts_with('+') || modifier.starts_with(".+");
                            if !value.split_whitespace().any(|s| {
                                if is_repeat {
                                    s.starts_with('+') || s.starts_with(".+")
                                } else {
                                    s.starts_with('-')
                                }
                            }) && value.ends_with('>')
                            {
                                value.insert_str(value.len() - 1, &format!(" {modifier}"));
                            }
                        }
                    }
                }
                let change = if kind == orgize::SyntaxKind::PLANNING_SCHEDULED {
                    TaskModification::Schedule(value.map(Into::into))
                } else {
                    TaskModification::Deadline(value.map(Into::into))
                };
                self.modify(target, change)?;
            }
            "tag!" => self.modify(
                target,
                TaskModification::Tags(Some(
                    arg(args, 0)?
                        .split(':')
                        .filter(|s| !s.is_empty())
                        .map(str::to_owned)
                        .collect(),
                )),
            )?,
            "set-priority!" => {
                let value = arg(args, 0)?;
                let current = self.prop(target, "PRIORITY")?.unwrap_or("B".into());
                let options = self.file.priority_options();
                let high = options.first().and_then(|p| p.name.bytes().next()).unwrap_or(b'A');
                let low = options.last().and_then(|p| p.name.bytes().next()).unwrap_or(b'C');
                let priority = match value {
                    " " => None,
                    "up" | "down" if self.node(target)?.priority().is_none() => Some(self.file.default_priority().name.clone()),
                    "up" | "down" => {
                        let now = current.bytes().next().unwrap_or(b'B');
                        // Org 在最高、最低和无显式优先级之间循环。
                        if value == "up" {
                            if now <= high {
                                None
                            } else {
                                Some(char::from(now - 1).to_string())
                            }
                        } else if now >= low {
                            None
                        } else {
                            Some(char::from(now + 1).to_string())
                        }
                    }
                    s => Some(s.into()),
                };
                self.modify(target, TaskModification::Priority(priority))?;
            }
            "set-property!" => {
                let name = arg(args, 0)?;
                let value = args.get(1).ok_or(error("TRIGGER 缺少属性值"))?;
                let new = match value {
                    Value::String(s) => s.clone(),
                    Value::Symbol(s) if s == "inc" || s == "dec" => {
                        let old = self
                            .prop(target, name)?
                            .ok_or(error("不能递增未设置的属性"))?;
                        let n = old.parse::<f64>().map_err(|_| error("属性不是数值"))?;
                        let n = n + if s == "inc" { 1.0 } else { -1.0 };
                        if !n.is_finite() {
                            return Err(error("属性数值溢出"));
                        }
                        n.to_string()
                    }
                    Value::Symbol(s) if ["next", "prev", "previous"].contains(&s.as_str()) => {
                        let allowed = self.allowed(target, name)?;
                        let old = self
                            .prop(target, name)?
                            .ok_or(error("不能循环未设置的属性"))?;
                        if allowed.is_empty() {
                            return Err(error("属性没有允许值列表"));
                        }
                        let at = allowed.iter().position(|s| s == &old);
                        let index = if s == "next" {
                            at.map_or(0, |at| (at + 1) % allowed.len())
                        } else {
                            at.map_or(allowed.len() - 1, |at| {
                                (at + allowed.len() - 1) % allowed.len()
                            })
                        };
                        allowed[index].clone()
                    }
                    _ => return Ok(()),
                };
                self.set_property(target, name, &new)?;
            }
            "delete-property!" => {
                let name = arg(args, 0)?;
                if ["CREATED", "CLOSED"]
                    .iter()
                    .any(|field| name.trim_end_matches('+').eq_ignore_ascii_case(field))
                {
                    return Err(error("创建时间不可修改"));
                }
                let node = metadata_node(self.file, &self.node(target)?);
                if let Some(drawer) = node.properties() {
                    let mut ranges = Vec::new();
                    for entry in drawer.node_properties() {
                        let raw = entry.raw();
                        if raw
                            .trim_start()
                            .split(':')
                            .nth(1)
                            .is_some_and(|s| s.trim_end_matches('+').eq_ignore_ascii_case(name))
                        {
                            ranges.push(
                                u32::from(entry.start()) as usize..u32::from(entry.end()) as usize,
                            );
                        }
                    }
                    for range in ranges.into_iter().rev() {
                        replace(self.file, range, &[])?;
                    }
                }
            }
            "chain!" => {
                let name = arg(args, 0)?;
                if let Some(value) = self.prop(source, name)? {
                    self.set_property(target, name, &value)?;
                }
            }
            "set-effort!" => {
                let value = args.first().ok_or(error("TRIGGER 缺少工作量"))?;
                let allowed = self.allowed(target, "EFFORT")?;
                let new = match value {
                    Value::String(s) => s.clone(),
                    Value::Number(n, true) => {
                        if allowed.is_empty() {
                            return Ok(());
                        }
                        let n = if *n == 0.0 { 10 } else { *n as usize };
                        allowed[n.saturating_sub(1).min(allowed.len() - 1)].clone()
                    }
                    Value::Symbol(s) if s == "increment" => {
                        let old = self.prop(target, "EFFORT")?;
                        let at = allowed
                            .iter()
                            .position(|s| Some(s) == old.as_ref())
                            .map_or(0, |n| n + 1);
                        allowed
                            .get(at)
                            .ok_or(error("工作量没有下一个允许值"))?
                            .clone()
                    }
                    _ => return Ok(()),
                };
                self.set_property(target, "EFFORT", &new)?;
            }
            // clock-in!/clock-out!/archive! 依赖宿主会话或跨文件写入，按用户约定静默跳过。
            _ => (),
        }
        Ok(())
    }
    fn modify(&mut self, target: usize, change: TaskModification) -> Result<()> {
        super::task_operation_executor::modify(self.file, &self.node(target)?, &change)
    }
    fn set_property(&mut self, target: usize, name: &str, value: &str) -> Result<()> {
        if name.is_empty()
            || name.chars().any(|c| c.is_whitespace() || c == ':')
            || value.contains(['\r', '\n'])
        {
            return Err(error("TRIGGER 属性名称或值无效"));
        }
        // 同 org-entry-put 的特殊属性：状态、优先级和标签通过其领域操作写入。
        match name.to_ascii_uppercase().as_str() {
            "TODO" => self.todo(target, (!value.is_empty()).then_some(value)),
            "PRIORITY" => self.modify(
                target,
                TaskModification::Priority((!value.trim().is_empty()).then(|| value.into())),
            ),
            "TAGS" => self.modify(
                target,
                TaskModification::Tags(Some(
                    value
                        .split(':')
                        .filter(|s| !s.is_empty())
                        .map(str::to_owned)
                        .collect(),
                )),
            ),
            "CREATED" | "CREATED+" | "CLOSED" | "CLOSED+" => {
                Err(error("创建和关闭时间不可由属性动作修改"))
            }
            _ => super::task_state::set_property(self.file, &self.node(target)?, name, value),
        }
    }
    fn allowed(&self, target: usize, name: &str) -> Result<Vec<String>> {
        let node = self.node(target)?;
        let values = property(self.file, &node, &format!("{name}_ALL"), true)?;
        Ok(values
            .unwrap_or_default()
            .split_whitespace()
            .map(str::to_owned)
            .collect())
    }
    fn matches(&self, target: usize, spec: &str) -> Result<bool> {
        matching::matches(spec, &self.own_tags(target)?, &|name| {
            if name.eq_ignore_ascii_case("LEVEL") {
                Ok(Some(self.node(target)?.level().to_string()))
            } else {
                self.prop(target, name)
            }
        })
    }
}
fn arg(args: &[Value], index: usize) -> Result<&str> {
    args.get(index).ok_or(error("TRIGGER 缺少参数"))?.text()
}
fn consider(value: &Value, values: &[bool]) -> Result<bool> {
    if values.is_empty() {
        return Ok(false);
    }
    let n = values.iter().filter(|v| **v).count();
    Ok(match value {
        Value::Symbol(s) if s == "any" || s == "nil" => n > 0,
        Value::Symbol(s) if s == "all" => n == values.len(),
        Value::Number(number, true) => n as f64 >= *number && n > 0,
        Value::Number(number, false) => n as f64 / values.len() as f64 >= *number && n > 0,
        _ => return Err(error("consider 参数无效")),
    })
}
fn effort(raw: &str) -> Result<f64> {
    if let Some((h, m)) = raw.split_once(':') {
        return Ok(
            h.parse::<f64>().map_err(|_| error("工作量格式无效"))? * 60.0
                + m.parse::<f64>().map_err(|_| error("工作量格式无效"))?,
        );
    }
    if let Ok(n) = raw.parse() {
        return Ok(n);
    }
    let mut total = 0.0;
    let mut rest = raw.trim();
    while !rest.is_empty() {
        let n = rest
            .bytes()
            .take_while(|c| c.is_ascii_digit() || *c == b'.')
            .count();
        if n == 0 {
            return Err(error("工作量格式无效"));
        }
        let number = rest[..n]
            .parse::<f64>()
            .map_err(|_| error("工作量格式无效"))?;
        rest = rest[n..].trim_start();
        let unit = rest.bytes().take_while(u8::is_ascii_alphabetic).count();
        let scale = match &rest[..unit] {
            "min" => 1.0,
            "h" => 60.0,
            "d" => 1440.0,
            "w" => 10080.0,
            "m" => 43200.0,
            "y" => 525960.0,
            _ => return Err(error("工作量单位无效")),
        };
        total += number * scale;
        rest = rest[unit..].trim_start();
    }
    Ok(total)
}

#[cfg(test)]
mod tests;
