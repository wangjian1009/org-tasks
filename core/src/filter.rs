use std::cmp::Ordering;

use chrono::{Datelike, Duration, Local, Months, NaiveDate};
use orgize::ast::{Headline, Timestamp};
use orgize::rowan::ast::AstNode;
use serde::Serialize;

use crate::OrgRepo;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Filter {
    pub expression: Option<FilterExpression>,
    pub sort_orders: Vec<FilterSort>,
    pub agenda_days: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FilterExpression {
    InBook {
        value: String,
        negated: bool,
    },
    State {
        value: String,
        negated: bool,
    },
    StateType {
        value: FilterStateType,
        negated: bool,
    },
    Priority {
        value: String,
        negated: bool,
    },
    SetPriority {
        value: String,
        negated: bool,
    },
    Tag {
        value: String,
        negated: bool,
    },
    OwnTag {
        value: String,
        negated: bool,
    },
    Date {
        field: FilterDateField,
        relation: FilterRelation,
        interval: FilterInterval,
    },
    Text {
        value: String,
        quoted: bool,
    },
    And(Vec<FilterExpression>),
    Or(Vec<FilterExpression>),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterStateType {
    Todo,
    Done,
    None,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterDateField {
    Event,
    Scheduled,
    Deadline,
    Closed,
    Created,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterRelation {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FilterInterval {
    pub unit: FilterIntervalUnit,
    pub value: i32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterIntervalUnit {
    None,
    Now,
    Hour,
    Day,
    Week,
    Month,
    Year,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FilterSort {
    pub field: FilterSortField,
    pub descending: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterSortField {
    Book,
    Title,
    Scheduled,
    Deadline,
    Event,
    Closed,
    Created,
    Priority,
    State,
    Position,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FilterTask {
    /// Core 生成的逻辑路径 MD5，不随字节位置、任务状态或首尾进度变化。
    pub id: String,
    pub repo_id: String,
    pub path: String,
    /// 所属文件的 CATEGORY；保留缺失与显式空值的区别。
    pub category: Option<String>,
    pub line: u32,
    pub column: u32,
    pub byte_offset: u64,
    pub level: u32,
    pub state: Option<String>,
    pub state_type: FilterStateType,
    pub priority: Option<String>,
    pub own_tags: Vec<String>,
    pub inherited_tags: Vec<String>,
    pub title: String,
    pub body: String,
    pub address_links: Vec<AddressLink>,
    /// 当前任务的计划或截止时间含重复器；不展开重复日期。
    pub is_repeating: bool,
    pub scheduled: Option<FilterDate>,
    pub deadline: Option<FilterDate>,
    pub closed: Option<FilterDate>,
    pub created: Option<FilterDate>,
    pub events: Vec<FilterDate>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AddressLink {
    pub uri: String,
    pub label: String,
}

impl FilterTask {
    /// 完成类型来自所属文件的有效 TODO 配置，不按状态名称推断。
    pub fn is_done(&self) -> bool {
        self.state_type == FilterStateType::Done
    }

    /// 查询匹配结束后移除系统用途标签，保留其余标签的原始顺序。
    pub(crate) fn exclude_refile_tag(&mut self) {
        self.own_tags.retain(|tag| tag != crate::model::REFILE_TAG);
        self.inherited_tags
            .retain(|tag| tag != crate::model::REFILE_TAG);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct FilterDate {
    pub date: NaiveDate,
    pub active: bool,
}

impl Filter {
    pub fn parse(source: &str) -> Self {
        let mut parser = DottedFilterParser::new(source);
        let expression = parser.parse_expression(false);
        Self {
            expression,
            sort_orders: parser.sort_orders,
            agenda_days: parser.agenda_days,
        }
    }

    pub fn matches(&self, task: &FilterTask) -> bool {
        self.matches_at(task, Local::now().date_naive())
    }

    pub fn matches_at(&self, task: &FilterTask, today: NaiveDate) -> bool {
        self.expression
            .as_ref()
            .is_none_or(|expression| matches_expression(expression, task, today))
    }

    pub fn filter_tasks(&self, tasks: &mut Vec<FilterTask>) {
        let today = Local::now().date_naive();
        tasks.retain(|task| self.matches_at(task, today));
        sort_tasks(tasks, &self.sort_orders);
    }
}

impl FilterInterval {
    pub fn parse(value: &str) -> Option<Self> {
        let lower = value.to_ascii_lowercase();
        match lower.as_str() {
            "none" | "no" => Some(Self {
                unit: FilterIntervalUnit::None,
                value: 0,
            }),
            "now" => Some(Self {
                unit: FilterIntervalUnit::Now,
                value: 0,
            }),
            "today" | "tod" => Some(Self {
                unit: FilterIntervalUnit::Day,
                value: 0,
            }),
            "tomorrow" | "tmrw" | "tom" => Some(Self {
                unit: FilterIntervalUnit::Day,
                value: 1,
            }),
            "yesterday" => Some(Self {
                unit: FilterIntervalUnit::Day,
                value: -1,
            }),
            _ => {
                let split = lower.len().checked_sub(1)?;
                let (number, unit) = lower.split_at(split);
                let value = number.parse().ok()?;
                let unit = match unit {
                    "h" => FilterIntervalUnit::Hour,
                    "d" => FilterIntervalUnit::Day,
                    "w" => FilterIntervalUnit::Week,
                    "m" => FilterIntervalUnit::Month,
                    "y" => FilterIntervalUnit::Year,
                    _ => return None,
                };
                Some(Self { unit, value })
            }
        }
    }
}

pub(crate) fn tasks_from_repo(repository: &OrgRepo) -> Vec<FilterTask> {
    let mut tasks = Vec::new();
    for file in repository.files() {
        if repository.task_scan_rules.excludes(&file.path) {
            continue;
        }
        let category = file.category();
        let mut ancestors: Vec<(usize, Vec<String>)> = Vec::new();
        let mut identities =
            crate::model::task_identity::TaskIdentity::new(&repository.root_directory, &file.path);
        for headline in file
            .syntax()
            .document()
            .syntax()
            .descendants()
            .filter_map(Headline::cast)
        {
            let level = headline.level();
            while ancestors
                .last()
                .is_some_and(|(ancestor_level, _)| *ancestor_level >= level)
            {
                ancestors.pop();
            }
            let own_tags = headline
                .tags()
                .map(|tag| tag.to_string())
                .collect::<Vec<_>>();
            let inherited_tags = ancestors
                .iter()
                .flat_map(|(_, tags)| tags.iter().cloned())
                .collect::<Vec<_>>();
            ancestors.push((level, own_tags.clone()));

            let offset = u32::from(headline.start()) as usize;
            let (line, column) = source_position(file.source_bytes(), offset);
            let body = headline
                .section()
                .map(|section| section.raw())
                .unwrap_or_default();
            let events = headline
                .section()
                .into_iter()
                .flat_map(|section| section.syntax().descendants().filter_map(Timestamp::cast))
                .filter(|timestamp| timestamp.is_active())
                .filter_map(timestamp_to_date)
                .collect();
            let state = headline.todo_keyword().map(|value| value.to_string());
            let state_type = match state.as_deref() {
                Some(value)
                    if file
                        .todo
                        .done_keywords
                        .iter()
                        .any(|keyword| keyword == value) =>
                {
                    FilterStateType::Done
                }
                Some(value)
                    if file
                        .todo
                        .pending_keywords
                        .iter()
                        .any(|keyword| keyword == value) =>
                {
                    FilterStateType::Todo
                }
                _ => FilterStateType::None,
            };
            let address_links = extract_address_links(&body);
            tasks.push(FilterTask {
                id: identities.id_for(&headline, state_type != FilterStateType::None),
                repo_id: repository.id.clone(),
                path: file.path.clone(),
                category: category.clone(),
                line,
                column,
                byte_offset: offset as u64,
                level: level as u32,
                state,
                state_type,
                priority: headline.priority().map(|value| value.to_string()),
                own_tags,
                inherited_tags,
                title: headline.title_raw().trim_end().to_owned(),
                body,
                address_links,
                is_repeating: planning_repeats(&headline),
                scheduled: planning_date(&headline, "SCHEDULED", headline.scheduled()),
                deadline: planning_date(&headline, "DEADLINE", headline.deadline()),
                closed: planning_date(&headline, "CLOSED", headline.closed()),
                created: None,
                events,
            });
        }
    }
    tasks.sort_by(|left, right| {
        left.path
            .cmp(&right.path)
            .then(left.byte_offset.cmp(&right.byte_offset))
    });
    tasks
}

fn extract_address_links(body: &str) -> Vec<AddressLink> {
    let mut result = Vec::new();
    let mut cursor = 0usize;
    while let Some(relative) = body[cursor..].find("[[") {
        let start = cursor + relative + 2;
        let Some(uri_end_relative) = body[start..].find(']') else { break };
        let uri_end = start + uri_end_relative;
        let uri = &body[start..uri_end];
        if !(uri.starts_with("geo:") || uri.starts_with("addr:")) { cursor = uri_end + 1; continue; }
        let label_start = uri_end + 2;
        let Some(label_end_relative) = body[label_start..].find("]]" ) else { break };
        let label_end = label_start + label_end_relative;
        result.push(AddressLink { uri: uri.to_owned(), label: body[label_start..label_end].to_owned() });
        cursor = label_end + 2;
    }
    result
}

fn timestamp_to_date(timestamp: Timestamp) -> Option<FilterDate> {
    let date = NaiveDate::from_ymd_opt(
        timestamp.year_start()?.to_string().parse().ok()?,
        timestamp.month_start()?.to_string().parse().ok()?,
        timestamp.day_start()?.to_string().parse().ok()?,
    )?;
    Some(FilterDate {
        date,
        active: timestamp.is_active(),
    })
}

// orgize 尚未识别的重复间隔写法沿用规划行的原文兜底，范围仅限标题后的规划行。
fn planning_repeats(headline: &Headline) -> bool {
    if [headline.scheduled(), headline.deadline()]
        .into_iter()
        .flatten()
        .any(|timestamp| timestamp.repeater_type().is_some())
    {
        return true;
    }
    headline
        .raw()
        .lines()
        .skip(1)
        .take_while(|line| {
            let line = line.trim_start();
            ["SCHEDULED:", "DEADLINE:", "CLOSED:"]
                .iter()
                .any(|keyword| line.starts_with(keyword))
        })
        .any(|line| {
            ["SCHEDULED:", "DEADLINE:"].iter().any(|keyword| {
                let Some((_, value)) = line.split_once(keyword) else {
                    return false;
                };
                let value = value.trim_start();
                if !value.starts_with(['<', '[']) {
                    return false;
                }
                let timestamp = value.split(['>', ']']).next().unwrap_or_default();
                timestamp.split_whitespace().any(|part| {
                    let Some(value) = part
                        .strip_prefix(".+")
                        .or_else(|| part.strip_prefix("++"))
                        .or_else(|| part.strip_prefix('+'))
                    else {
                        return false;
                    };
                    let count = value.bytes().take_while(u8::is_ascii_digit).count();
                    count > 0
                        && value[..count].parse::<u32>().is_ok_and(|n| n > 0)
                        && matches!(
                            value.as_bytes().get(count),
                            Some(b'h' | b'd' | b'w' | b'm' | b'y')
                        )
                        && (value.len() == count + 1
                            || value.as_bytes().get(count + 1) == Some(&b'/'))
                })
            })
        })
}

fn planning_date(
    headline: &Headline,
    keyword: &str,
    timestamp: Option<Timestamp>,
) -> Option<FilterDate> {
    timestamp.and_then(timestamp_to_date).or_else(|| {
        headline
            .raw()
            .lines()
            .take_while(|line| {
                line.chars()
                    .take_while(|character| *character == '*')
                    .count()
                    <= headline.level()
            })
            .find_map(|line| parse_planning_line(line, keyword))
    })
}

fn parse_planning_line(line: &str, keyword: &str) -> Option<FilterDate> {
    let value = line
        .trim_start()
        .strip_prefix(&format!("{keyword}:"))?
        .trim_start();
    let opener = value.chars().next()?;
    if opener != '<' && opener != '[' {
        return None;
    }
    let date = NaiveDate::parse_from_str(value.get(1..11)?, "%Y-%m-%d").ok()?;
    Some(FilterDate {
        date,
        active: opener == '<',
    })
}

fn source_position(source: &[u8], offset: usize) -> (u32, u32) {
    let mut line = 1;
    let mut column = 0;
    for byte in &source[..offset] {
        if *byte == b'\n' {
            line += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    (line, column)
}

fn matches_expression(expression: &FilterExpression, task: &FilterTask, today: NaiveDate) -> bool {
    match expression {
        FilterExpression::InBook { value, negated } => {
            apply_negation(task.path == *value, *negated)
        }
        FilterExpression::State { value, negated } => apply_negation(
            task.state
                .as_deref()
                .is_some_and(|state| state.eq_ignore_ascii_case(value)),
            *negated,
        ),
        FilterExpression::StateType { value, negated } => {
            apply_negation(task.state_type == *value, *negated)
        }
        FilterExpression::Priority { value, negated } => apply_negation(
            task.priority
                .as_deref()
                .unwrap_or("B")
                .eq_ignore_ascii_case(value),
            *negated,
        ),
        FilterExpression::SetPriority { value, negated } => apply_negation(
            task.priority
                .as_deref()
                .is_some_and(|priority| priority.eq_ignore_ascii_case(value)),
            *negated,
        ),
        FilterExpression::Tag { value, negated } => apply_negation(
            task.own_tags
                .iter()
                .chain(&task.inherited_tags)
                .any(|tag| tag.contains(value)),
            *negated,
        ),
        FilterExpression::OwnTag { value, negated } => apply_negation(
            task.own_tags.iter().any(|tag| tag.contains(value)),
            *negated,
        ),
        FilterExpression::Date {
            field,
            relation,
            interval,
        } => {
            let dates = dates_for_field(task, *field);
            if interval.unit == FilterIntervalUnit::None {
                return dates.is_empty();
            }
            dates.iter().any(|date| {
                (matches!(
                    field,
                    FilterDateField::Scheduled | FilterDateField::Deadline
                ) && !date.active)
                    .not()
                    && date_matches(*date, *relation, *interval, today)
            })
        }
        FilterExpression::Text { value, .. } => {
            let value = value.to_ascii_lowercase();
            task.title.to_ascii_lowercase().contains(&value)
                || task.body.to_ascii_lowercase().contains(&value)
                || task
                    .own_tags
                    .iter()
                    .chain(&task.inherited_tags)
                    .any(|tag| tag.to_ascii_lowercase().contains(&value))
        }
        FilterExpression::And(operands) => operands
            .iter()
            .all(|operand| matches_expression(operand, task, today)),
        FilterExpression::Or(operands) => operands
            .iter()
            .any(|operand| matches_expression(operand, task, today)),
    }
}

fn apply_negation(value: bool, negated: bool) -> bool {
    if negated { !value } else { value }
}

fn dates_for_field(task: &FilterTask, field: FilterDateField) -> Vec<FilterDate> {
    match field {
        FilterDateField::Scheduled => task.scheduled.into_iter().collect(),
        FilterDateField::Deadline => task.deadline.into_iter().collect(),
        FilterDateField::Closed => task.closed.into_iter().collect(),
        FilterDateField::Created => task.created.into_iter().collect(),
        FilterDateField::Event => task.events.clone(),
    }
}

fn date_matches(
    date: FilterDate,
    relation: FilterRelation,
    interval: FilterInterval,
    today: NaiveDate,
) -> bool {
    let target = interval_date(interval, today);
    match relation {
        FilterRelation::Eq => date.date == target,
        FilterRelation::Ne => date.date != target,
        FilterRelation::Lt => date.date < target,
        FilterRelation::Le => date.date <= target,
        FilterRelation::Gt => date.date > target,
        FilterRelation::Ge => date.date >= target,
    }
}

fn interval_date(interval: FilterInterval, today: NaiveDate) -> NaiveDate {
    match interval.unit {
        FilterIntervalUnit::None
        | FilterIntervalUnit::Now
        | FilterIntervalUnit::Day
        | FilterIntervalUnit::Hour => today + Duration::days(interval.value as i64),
        FilterIntervalUnit::Week => today + Duration::weeks(interval.value as i64),
        FilterIntervalUnit::Month => today
            .checked_add_months(Months::new(interval.value.unsigned_abs()))
            .map_or(today, |date| {
                if interval.value < 0 {
                    today
                        .checked_sub_months(Months::new(interval.value.unsigned_abs()))
                        .unwrap_or(today)
                } else {
                    date
                }
            }),
        FilterIntervalUnit::Year => {
            NaiveDate::from_ymd_opt(today.year() + interval.value, today.month(), today.day())
                .unwrap_or(today)
        }
    }
}

fn sort_tasks(tasks: &mut [FilterTask], orders: &[FilterSort]) {
    tasks.sort_by(|left, right| {
        for order in orders {
            let result = compare_sort(left, right, order.field);
            if result != Ordering::Equal {
                return if order.descending {
                    result.reverse()
                } else {
                    result
                };
            }
        }
        left.path
            .cmp(&right.path)
            .then(left.byte_offset.cmp(&right.byte_offset))
    });
}

fn compare_sort(left: &FilterTask, right: &FilterTask, field: FilterSortField) -> Ordering {
    match field {
        FilterSortField::Book => left.path.cmp(&right.path),
        FilterSortField::Title => left.title.cmp(&right.title),
        FilterSortField::Priority => left.priority.cmp(&right.priority),
        FilterSortField::State => left.state.cmp(&right.state),
        FilterSortField::Scheduled => left.scheduled.cmp(&right.scheduled),
        FilterSortField::Deadline => left.deadline.cmp(&right.deadline),
        FilterSortField::Closed => left.closed.cmp(&right.closed),
        FilterSortField::Created => left.created.cmp(&right.created),
        FilterSortField::Event => left.events.first().cmp(&right.events.first()),
        FilterSortField::Position => left
            .path
            .cmp(&right.path)
            .then(left.byte_offset.cmp(&right.byte_offset)),
    }
}

struct DottedFilterParser {
    tokens: Vec<String>,
    position: usize,
    sort_orders: Vec<FilterSort>,
    agenda_days: Option<u32>,
}

impl DottedFilterParser {
    fn new(source: &str) -> Self {
        Self {
            tokens: tokenize(source),
            position: 0,
            sort_orders: Vec::new(),
            agenda_days: None,
        }
    }

    fn parse_expression(&mut self, stop_at_close: bool) -> Option<FilterExpression> {
        self.parse_or(stop_at_close)
    }

    fn parse_or(&mut self, stop_at_close: bool) -> Option<FilterExpression> {
        let mut operands = Vec::new();
        if let Some(expression) = self.parse_and(stop_at_close) {
            operands.push(expression);
        }
        while self.peek_is("or") {
            self.position += 1;
            if let Some(expression) = self.parse_and(stop_at_close) {
                operands.push(expression);
            }
        }
        combine_or(operands)
    }

    fn parse_and(&mut self, stop_at_close: bool) -> Option<FilterExpression> {
        let mut operands = Vec::new();
        while let Some(token) = self.peek() {
            if stop_at_close && token == ")" {
                break;
            }
            if token.eq_ignore_ascii_case("or") {
                break;
            }
            if token.eq_ignore_ascii_case("and") {
                self.position += 1;
                continue;
            }
            if token == "(" {
                self.position += 1;
                if let Some(expression) = self.parse_expression(true) {
                    operands.push(expression);
                }
                if self.peek() == Some(")") {
                    self.position += 1;
                }
                continue;
            }
            if token == ")" {
                self.position += 1;
                continue;
            }
            let token = self.next().unwrap_or_default();
            if let Some(expression) = self.parse_term(&token) {
                operands.push(expression);
            }
        }
        combine_and(operands)
    }

    fn parse_term(&mut self, token: &str) -> Option<FilterExpression> {
        if let Some(order) = parse_sort(token) {
            self.sort_orders.push(order);
            return None;
        }
        if let Some(days) = token
            .strip_prefix("ad.")
            .and_then(|value| value.parse::<u32>().ok())
            .filter(|value| *value > 0)
        {
            self.agenda_days = Some(days);
            return None;
        }
        Some(
            parse_condition(token).unwrap_or_else(|| FilterExpression::Text {
                value: unquote(token),
                quoted: token != unquote(token),
            }),
        )
    }

    fn peek(&self) -> Option<&str> {
        self.tokens.get(self.position).map(String::as_str)
    }
    fn peek_is(&self, value: &str) -> bool {
        self.peek()
            .is_some_and(|token| token.eq_ignore_ascii_case(value))
    }
    fn next(&mut self) -> Option<String> {
        let token = self.tokens.get(self.position)?.clone();
        self.position += 1;
        Some(token)
    }
}

fn combine_and(mut operands: Vec<FilterExpression>) -> Option<FilterExpression> {
    match operands.len() {
        0 => None,
        1 => Some(operands.remove(0)),
        _ => Some(FilterExpression::And(operands)),
    }
}

fn combine_or(mut operands: Vec<FilterExpression>) -> Option<FilterExpression> {
    match operands.len() {
        0 => None,
        1 => Some(operands.remove(0)),
        _ => Some(FilterExpression::Or(operands)),
    }
}

fn parse_condition(token: &str) -> Option<FilterExpression> {
    let (negated, token) = token
        .strip_prefix('.')
        .map_or((false, token), |value| (true, value));
    for (prefix, constructor) in [
        ("it.", 0),
        ("ps.", 1),
        ("tn.", 2),
        ("b.", 3),
        ("i.", 4),
        ("p.", 5),
        ("t.", 6),
    ] {
        if let Some(value) = token.strip_prefix(prefix) {
            if value.is_empty() {
                return None;
            }
            return match constructor {
                0 => match value {
                    "todo" => Some(FilterExpression::StateType {
                        value: FilterStateType::Todo,
                        negated,
                    }),
                    "done" => Some(FilterExpression::StateType {
                        value: FilterStateType::Done,
                        negated,
                    }),
                    "none" => Some(FilterExpression::StateType {
                        value: FilterStateType::None,
                        negated,
                    }),
                    _ => None,
                },
                1 => single_letter(value)
                    .map(|value| FilterExpression::SetPriority { value, negated }),
                2 => Some(FilterExpression::OwnTag {
                    value: unquote(value),
                    negated,
                }),
                3 => Some(FilterExpression::InBook {
                    value: unquote(value),
                    negated,
                }),
                4 => Some(FilterExpression::State {
                    value: unquote(value),
                    negated,
                }),
                5 => {
                    single_letter(value).map(|value| FilterExpression::Priority { value, negated })
                }
                _ => Some(FilterExpression::Tag {
                    value: unquote(value),
                    negated,
                }),
            };
        }
    }
    if negated {
        return None;
    }
    parse_date_condition(token)
}

fn single_letter(value: &str) -> Option<String> {
    (value.chars().count() == 1 && value.chars().all(char::is_alphabetic)).then(|| value.into())
}

fn parse_date_condition(token: &str) -> Option<FilterExpression> {
    let mut parts = token.split('.');
    let field = match parts.next()? {
        "e" => FilterDateField::Event,
        "s" => FilterDateField::Scheduled,
        "d" => FilterDateField::Deadline,
        "c" => FilterDateField::Closed,
        "cr" => FilterDateField::Created,
        _ => return None,
    };
    let second = parts.next()?;
    let (relation, interval) = match parse_relation(second) {
        Some(relation) => (relation, parts.next()?),
        None => (default_relation(field), second),
    };
    if parts.next().is_some() {
        return None;
    }
    Some(FilterExpression::Date {
        field,
        relation,
        interval: FilterInterval::parse(&unquote(interval))?,
    })
}

fn parse_relation(value: &str) -> Option<FilterRelation> {
    match value {
        "eq" => Some(FilterRelation::Eq),
        "ne" => Some(FilterRelation::Ne),
        "lt" => Some(FilterRelation::Lt),
        "le" => Some(FilterRelation::Le),
        "gt" => Some(FilterRelation::Gt),
        "ge" => Some(FilterRelation::Ge),
        _ => None,
    }
}

fn default_relation(field: FilterDateField) -> FilterRelation {
    match field {
        FilterDateField::Event | FilterDateField::Closed => FilterRelation::Eq,
        _ => FilterRelation::Le,
    }
}

fn parse_sort(token: &str) -> Option<FilterSort> {
    let (descending, token) = token
        .strip_prefix('.')
        .map_or((false, token), |value| (true, value));
    let field = match token.strip_prefix("o.")? {
        "notebook" | "book" | "b" => FilterSortField::Book,
        "title" | "t" => FilterSortField::Title,
        "scheduled" | "sched" | "s" => FilterSortField::Scheduled,
        "deadline" | "dead" | "d" => FilterSortField::Deadline,
        "event" | "e" => FilterSortField::Event,
        "closed" | "close" | "c" => FilterSortField::Closed,
        "created" | "cr" => FilterSortField::Created,
        "priority" | "prio" | "pri" | "p" => FilterSortField::Priority,
        "state" | "st" => FilterSortField::State,
        "position" | "pos" => FilterSortField::Position,
        _ => return None,
    };
    Some(FilterSort { field, descending })
}

fn tokenize(source: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut token = String::new();
    let mut quoted = false;
    let mut escaped = false;
    for character in source.chars() {
        if quoted {
            token.push(character);
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                quoted = false;
            }
            continue;
        }
        match character {
            '"' => {
                quoted = true;
                token.push(character);
            }
            '(' | ')' => {
                if !token.is_empty() {
                    tokens.push(std::mem::take(&mut token));
                }
                tokens.push(character.into());
            }
            character if character.is_whitespace() => {
                if !token.is_empty() {
                    tokens.push(std::mem::take(&mut token));
                }
            }
            _ => token.push(character),
        }
    }
    if !token.is_empty() {
        tokens.push(token);
    }
    tokens
}

fn unquote(value: &str) -> String {
    if value.len() < 2 || !value.starts_with('"') || !value.ends_with('"') {
        return value.into();
    }
    let mut output = String::new();
    let mut escaped = false;
    for character in value[1..value.len() - 1].chars() {
        if escaped {
            output.push(character);
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else {
            output.push(character);
        }
    }
    output
}

trait BoolNot {
    fn not(self) -> bool;
}
impl BoolNot for bool {
    fn not(self) -> bool {
        !self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::OrgFile;

    #[test]
    fn ports_reference_tokenizer_cases() {
        assert_eq!(tokenize("(a)"), ["(", "a", ")"]);
        assert_eq!(
            tokenize("((a) \"c \\\"  d\")"),
            ["(", "(", "a", ")", "\"c \\\"  d\"", ")"]
        );
        assert_eq!(tokenize("((a.\"b c\"))"), ["(", "(", "a.\"b c\"", ")", ")"]);
    }

    #[test]
    fn ports_reference_boolean_precedence_and_quotes() {
        let filter = Filter::parse("i.todo or i.next t.work");
        assert_eq!(
            filter.expression,
            Some(FilterExpression::Or(vec![
                FilterExpression::State {
                    value: "todo".into(),
                    negated: false
                },
                FilterExpression::And(vec![
                    FilterExpression::State {
                        value: "next".into(),
                        negated: false
                    },
                    FilterExpression::Tag {
                        value: "work".into(),
                        negated: false
                    },
                ]),
            ]))
        );
        assert_eq!(
            Filter::parse("b.\"book(1) name\"").expression,
            Some(FilterExpression::InBook {
                value: "book(1) name".into(),
                negated: false
            })
        );
    }

    #[test]
    fn ports_reference_interval_sort_and_agenda_cases() {
        let filter = Filter::parse("s.le.2w .o.p ad.2");
        assert_eq!(filter.agenda_days, Some(2));
        assert_eq!(
            filter.sort_orders,
            vec![FilterSort {
                field: FilterSortField::Priority,
                descending: true
            }]
        );
        assert_eq!(
            filter.expression,
            Some(FilterExpression::Date {
                field: FilterDateField::Scheduled,
                relation: FilterRelation::Le,
                interval: FilterInterval {
                    unit: FilterIntervalUnit::Week,
                    value: 2
                }
            })
        );
        assert_eq!(
            FilterInterval::parse("tom"),
            Some(FilterInterval {
                unit: FilterIntervalUnit::Day,
                value: 1
            })
        );
        assert_eq!(
            FilterInterval::parse("no"),
            Some(FilterInterval {
                unit: FilterIntervalUnit::None,
                value: 0
            })
        );
    }

    #[test]
    fn filters_tasks_with_reference_state_tag_and_date_semantics() {
        let file = OrgFile::new("repo".into(), "work.org".into(), b"* TODO Parent :work:\n** DONE Child :home:\nSCHEDULED: <2024-01-03 Wed>\n* TODO Other\n* Plain heading\n".to_vec()).unwrap();
        let repository = OrgRepo {
            id: "repo".into(),
            root_directory: "/tmp".into(),
            todo_defaults: crate::TodoConfig::default(),
            task_scan_rules: Default::default(),
            files: vec![file],
        };
        let tasks = tasks_from_repo(&repository);
        assert_eq!(tasks.len(), 4);
        assert_eq!(
            tasks.iter().map(|task| task.level).collect::<Vec<_>>(),
            vec![1, 2, 1, 1]
        );
        let tag_filter = Filter::parse("t.work");
        assert_eq!(
            tasks
                .iter()
                .filter(|task| tag_filter
                    .matches_at(task, NaiveDate::from_ymd_opt(2024, 1, 1).unwrap()))
                .count(),
            2
        );
        let date_filter = Filter::parse("s.2d");
        assert_eq!(
            tasks
                .iter()
                .filter(|task| date_filter
                    .matches_at(task, NaiveDate::from_ymd_opt(2024, 1, 1).unwrap()))
                .count(),
            1
        );
        let state_filter = Filter::parse("it.done");
        assert_eq!(
            tasks
                .iter()
                .filter(|task| state_filter
                    .matches_at(task, NaiveDate::from_ymd_opt(2024, 1, 1).unwrap()))
                .count(),
            1
        );
        let not_done_filter = Filter::parse(".it.done");
        assert_eq!(
            tasks
                .iter()
                .filter(|task| not_done_filter
                    .matches_at(task, NaiveDate::from_ymd_opt(2024, 1, 1).unwrap()))
                .count(),
            3
        );
    }

    #[test]
    fn file_level_cancel_state_is_done_in_task_projection() {
        let file = OrgFile::with_todo_defaults(
            "repo".into(),
            "work.org".into(),
            b"#+TODO: TODO | DONE CNCL\n* CNCL Cancelled\n".to_vec(),
            crate::TodoConfig::default(),
        )
        .unwrap();
        let repository = OrgRepo {
            id: "repo".into(),
            root_directory: "/tmp".into(),
            todo_defaults: crate::TodoConfig::default(),
            task_scan_rules: Default::default(),
            files: vec![file],
        };
        let task = tasks_from_repo(&repository).pop().unwrap();
        assert_eq!(task.state.as_deref(), Some("CNCL"));
        assert_eq!(task.state_type, FilterStateType::Done);
    }

    #[test]
    fn is_done_follows_each_files_in_buffer_configuration() {
        let defaults = crate::TodoConfig::from_settings("#+TODO: GLOBAL | CNCL").unwrap();
        let sources = [
            (
                "cancelled.org",
                "#+TODO: TODO | DONE\n#+TODO: | CNCL\n* CNCL Cancelled\n",
                true,
            ),
            (
                "pending.org",
                "#+TODO: CNCL | FINISHED\n* CNCL Pending\n",
                false,
            ),
            ("cleared.org", "#+TODO:\n* CNCL Plain\n", false),
            ("global.org", "* CNCL Done by default\n", true),
            ("plain.org", "* No state\n", false),
        ];
        let repository = OrgRepo {
            id: "repo".into(),
            root_directory: "/tmp".into(),
            todo_defaults: defaults.clone(),
            task_scan_rules: Default::default(),
            files: sources
                .iter()
                .map(|(path, source, _)| {
                    OrgFile::with_todo_defaults(
                        "repo".into(),
                        (*path).into(),
                        source.as_bytes().to_vec(),
                        defaults.clone(),
                    )
                    .unwrap()
                })
                .collect(),
        };
        let tasks = tasks_from_repo(&repository);
        for (path, _, expected) in sources {
            let task = tasks.iter().find(|task| task.path == path).unwrap();
            assert_eq!(task.is_done(), expected, "{path}");
            assert_eq!(Filter::parse("it.done").matches(task), task.is_done());
        }
    }

    #[test]
    fn projects_scheduled_timestamp_with_repeater() {
        let file = OrgFile::new(
            "repo".into(),
            "work.org".into(),
            b"* TODO Repeated\nSCHEDULED: <2026-09-27 Sun .+4w/5w>\n".to_vec(),
        )
        .unwrap();
        let repository = OrgRepo {
            id: "repo".into(),
            root_directory: "/tmp".into(),
            todo_defaults: crate::TodoConfig::default(),
            task_scan_rules: Default::default(),
            files: vec![file],
        };
        let task = tasks_from_repo(&repository).pop().unwrap();
        assert_eq!(
            task.scheduled,
            Some(FilterDate {
                date: NaiveDate::from_ymd_opt(2026, 9, 27).unwrap(),
                active: true,
            })
        );
    }
}
