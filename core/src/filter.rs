use std::cmp::Ordering;
use std::sync::Arc;

use chrono::{Datelike, Duration, Local, Months, NaiveDate, TimeZone};
use orgize::ast::{Headline, Link, TimeUnit, Timestamp};
use orgize::rowan::ast::AstNode;
use serde::Serialize;

use crate::OrgRepo;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Filter {
    expression: Option<FilterExpression>,
    sort_orders: Vec<FilterSort>,
    agenda_days: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum FilterExpression {
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
    HasAddressLink {
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
enum FilterDateField {
    Event,
    Scheduled,
    Deadline,
    Closed,
    Created,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FilterRelation {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FilterInterval {
    unit: FilterIntervalUnit,
    value: i32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FilterIntervalUnit {
    None,
    Now,
    Hour,
    Day,
    Week,
    Month,
    Year,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FilterSort {
    field: FilterSortField,
    descending: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FilterSortField {
    Book,
    Title,
    Scheduled,
    Deadline,
    Event,
    Closed,
    Created,
    Modified,
    Priority,
    State,
    Position,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FilterTask {
    /// 兼容既有调用方的明文逻辑身份；任务专属身份请使用 task_id()。
    pub(crate) id: String,
    pub(crate) full_path: crate::TaskPath,
    pub(crate) file_metadata: Arc<crate::OrgFileMetadata>,
    file_version: String,
    edit_content: crate::TaskEditContent,
    pub(crate) support_tags: Option<Arc<crate::SupportTags>>,
    /// 所属文件的 CATEGORY；保留缺失与显式空值的区别。
    pub(crate) category: Option<String>,
    pub(crate) line: u32,
    pub(crate) column: u32,
    pub(crate) byte_offset: u64,
    pub(crate) level: u32,
    pub(crate) state: Option<crate::TaskState>,
    pub(crate) state_type: FilterStateType,
    pub(crate) priority: Option<String>,
    pub(crate) own_tags: Vec<String>,
    pub(crate) inherited_tags: Vec<String>,
    pub(crate) title: String,
    pub(crate) body: String,
    pub(crate) address_links: Vec<AddressLink>,
    /// 当前任务的计划或截止时间含重复器；不展开重复日期。
    pub(crate) is_repeating: bool,
    pub(crate) scheduled: Option<FilterDate>,
    pub(crate) deadline: Option<FilterDate>,
    /// Org-mode 规划时间预警期的起始日期，仅供 Core 的 <= 日期查询使用。
    pub(crate) scheduled_warning: Option<NaiveDate>,
    pub(crate) deadline_warning: Option<NaiveDate>,
    pub(crate) closed: Option<FilterDate>,
    pub(crate) created: Option<FilterDate>,
    pub(crate) created_at: Option<crate::TimestampMs>,
    pub(crate) modified_at: Option<crate::TimestampMs>,
    pub(crate) events: Vec<FilterDate>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AddressLink {
    pub uri: String,
    pub label: String,
}

impl FilterTask {
    pub fn file_version(&self) -> &str {
        &self.file_version
    }
    pub fn edit_content(&self) -> &crate::TaskEditContent {
        &self.edit_content
    }
    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn task_id(&self) -> Option<&str> {
        (self.state_type != FilterStateType::None).then_some(self.id.as_str())
    }

    pub fn full_path(&self) -> &crate::TaskPath {
        &self.full_path
    }

    pub fn repo_id(&self) -> &str {
        &self.file_metadata.repo_id
    }

    pub fn path(&self) -> &str {
        &self.file_metadata.path
    }

    /// 同一文件的任务共享不可变元信息，任务克隆继续共享该快照。
    pub fn file_metadata(&self) -> &crate::OrgFileMetadata {
        &self.file_metadata
    }

    /// 项目名称来自共享文件元信息，不重新解析或读取所属文件。
    pub fn project(&self) -> Option<&str> {
        self.file_metadata.project()
    }

    pub fn support_tags(&self) -> Option<&crate::SupportTags> {
        self.support_tags.as_deref()
    }

    pub fn category(&self) -> Option<&str> {
        self.category.as_deref()
    }

    pub fn line(&self) -> u32 {
        self.line
    }

    pub fn column(&self) -> u32 {
        self.column
    }

    pub fn byte_offset(&self) -> u64 {
        self.byte_offset
    }

    pub fn level(&self) -> u32 {
        self.level
    }

    pub fn state(&self) -> Option<&crate::TaskState> {
        self.state.as_ref()
    }

    pub fn task_state_of(&self, category: crate::TaskStateCategory) -> Option<crate::TaskState> {
        self.file_metadata.task_state_of(category)
    }

    pub(crate) fn state_name(&self) -> Option<&str> {
        self.state.as_ref().map(|state| state.name.as_str())
    }

    #[cfg(test)]
    pub(crate) fn state_type(&self) -> FilterStateType {
        self.state_type
    }

    pub fn priority(&self) -> Option<&str> {
        self.priority.as_deref()
    }

    pub fn own_tags(&self) -> &[String] {
        &self.own_tags
    }

    pub fn inherited_tags(&self) -> &[String] {
        &self.inherited_tags
    }

    pub fn title(&self) -> &str {
        &self.title
    }

    pub fn body(&self) -> &str {
        &self.body
    }

    pub fn address_links(&self) -> &[AddressLink] {
        &self.address_links
    }

    pub fn is_repeating(&self) -> bool {
        self.is_repeating
    }

    pub fn scheduled(&self) -> Option<FilterDate> {
        self.scheduled
    }

    pub fn deadline(&self) -> Option<FilterDate> {
        self.deadline
    }

    pub fn closed(&self) -> Option<FilterDate> {
        self.closed
    }

    pub fn created(&self) -> Option<FilterDate> {
        self.created
    }

    pub fn created_at(&self) -> Option<crate::TimestampMs> {
        self.created_at
    }

    /// 当前标题自身 LAST_MODIFIED 属性的时间；缺失或无效时为空。
    pub fn modified_at(&self) -> Option<crate::TimestampMs> {
        self.modified_at
    }

    pub fn events(&self) -> &[FilterDate] {
        &self.events
    }

    /// 完成类型来自所属文件的有效 TODO 配置，不按状态名称推断。
    pub fn is_done(&self) -> bool {
        self.state
            .as_ref()
            .and_then(|state| state.category)
            .is_some_and(crate::TaskStateCategory::is_done)
    }

    /// 查询匹配结束后移除系统用途标签，保留其余标签的原始顺序。
    pub(crate) fn exclude_system_tags(&mut self) {
        let visible = |tag: &String| {
            ![
                crate::model::REFILE_TAG,
                crate::model::ARCHIVE_TAG,
                crate::model::CONFLICT_TAG,
            ]
            .contains(&tag.as_str())
        };
        self.own_tags.retain(visible);
        self.inherited_tags.retain(visible);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct FilterDate {
    pub(crate) date: NaiveDate,
    pub(crate) active: bool,
}

impl FilterDate {
    pub fn date(&self) -> NaiveDate {
        self.date
    }

    pub fn is_active(&self) -> bool {
        self.active
    }
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

    #[cfg(test)]
    fn matches(&self, task: &FilterTask) -> bool {
        self.matches_at(task, Local::now().date_naive())
    }

    fn matches_at(&self, task: &FilterTask, today: NaiveDate) -> bool {
        self.expression
            .as_ref()
            .is_none_or(|expression| matches_expression(expression, task, today))
    }

    #[cfg(test)]
    pub fn filter_tasks(&self, tasks: &mut Vec<FilterTask>) {
        self.filter_tasks_at(tasks, Local::now().date_naive());
    }

    pub(crate) fn filter_tasks_at(&self, tasks: &mut Vec<FilterTask>, today: NaiveDate) {
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

#[cfg(test)]
pub(crate) async fn tasks_from_repo(
    repository: &OrgRepo,
) -> Result<Vec<FilterTask>, crate::CoreError> {
    let files = repository.load_files(&[]).await?;
    Ok(files
        .iter()
        .filter(|file| !file.scan_ignored)
        .flat_map(|file| tasks_from_file(repository, file))
        .collect())
}

pub(crate) fn tasks_from_file(repository: &OrgRepo, file: &crate::OrgFile) -> Vec<FilterTask> {
    let mut tasks = Vec::new();
    let file_metadata = Arc::new(file.metadata(file.scan_ignored));
    let file_version = crate::LocalFileVersion::from_bytes(file.source_bytes()).content_hash;
    let support_tags = file.support_tags().map(Arc::new);
    let category = file.category();
    let mut ancestors: Vec<(usize, Vec<String>)> = Vec::new();
    let mut identities =
        crate::model::task_identity::TaskIdentity::new(&repository.root_directory, &file.path);
    for (full_path, headline) in file.path_headlines() {
        if crate::OrgFile::is_conflict_headline(&headline) {
            continue;
        }
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
        let state = headline.todo_keyword().map(|value| crate::TaskState {
            name: value.to_string(),
            category: file.todo.category(value.as_ref()),
        });
        let state_type = match state.as_ref() {
            Some(state)
                if state
                    .category
                    .is_some_and(crate::TaskStateCategory::is_done) =>
            {
                FilterStateType::Done
            }
            Some(_) => FilterStateType::Todo,
            None => FilterStateType::None,
        };
        let address_links = extract_address_links(&headline);
        let created = property_time(&headline, "CREATED");
        let edit_content = file
            .task_edit_content(&full_path)
            .expect("同一语法树生成的任务路径必须可定位");
        tasks.push(FilterTask {
            file_version: file_version.clone(),
            edit_content,
            id: identities.id_for(&headline, state_type != FilterStateType::None),
            full_path,
            file_metadata: Arc::clone(&file_metadata),
            support_tags: support_tags.clone(),
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
            scheduled_warning: planning_warning(&headline, "SCHEDULED", headline.scheduled()),
            deadline_warning: planning_warning(&headline, "DEADLINE", headline.deadline()),
            closed: planning_date(&headline, "CLOSED", headline.closed()),
            created: created.map(|value| value.0),
            created_at: created.map(|value| value.1),
            modified_at: property_time(&headline, "LAST_MODIFIED").map(|value| value.1),
            events,
        });
    }
    tasks
}

// 时间属性仅从当前标题自身的属性抽屉读取，不继承、不扫描正文或文件前言。
fn property_time(headline: &Headline, property: &str) -> Option<(FilterDate, crate::TimestampMs)> {
    let value = crate::model::properties::own(headline, property)?;
    let value = value.trim();
    let timestamp = orgize::Org::parse(value).first_node::<Timestamp>()?;
    if timestamp.raw() != value || timestamp.is_range() {
        return None;
    }
    let date = timestamp_to_date(timestamp.clone())?;
    let (hour, minute) = match (timestamp.hour_start(), timestamp.minute_start()) {
        (None, None) => (0, 0),
        (Some(hour), Some(minute)) => (hour.parse().ok()?, minute.parse().ok()?),
        _ => return None,
    };
    let local = date.date.and_hms_opt(hour, minute, 0)?;
    Some((
        date,
        Local
            .from_local_datetime(&local)
            .earliest()?
            .timestamp_millis(),
    ))
}

fn extract_address_links(headline: &Headline) -> Vec<AddressLink> {
    // 使用真实链接节点，排除源码、示例和行内字面文本；子标题的地址只归属子标题。
    headline
        .syntax()
        .children()
        .filter(|node| !Headline::can_cast(node.kind()))
        .flat_map(|node| node.descendants())
        .filter_map(Link::cast)
        .filter_map(|link| {
            let uri = link.path().to_string();
            (uri.strip_prefix("geo:")
                .or_else(|| uri.strip_prefix("addr:"))
                .is_some_and(|value| !value.is_empty()))
            .then(|| AddressLink {
                uri,
                label: link.description_raw(),
            })
        })
        .collect()
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
// 语法与 Org-mode 的 timestamp repeater 一致：+Nunit、++Nunit、.+Nunit，
// 以及可选的 /N 或 /Nunit 重复截止部分。
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
                timestamp.split_whitespace().any(has_org_repeater)
            })
        })
}

fn has_org_repeater(part: &str) -> bool {
    let Some(value) = part
        .strip_prefix(".+")
        .or_else(|| part.strip_prefix("++"))
        .or_else(|| part.strip_prefix('+'))
    else {
        return false;
    };
    let interval_digits = value.bytes().take_while(u8::is_ascii_digit).count();
    if interval_digits == 0 {
        return false;
    }
    let Some(interval_unit) = value.as_bytes().get(interval_digits) else {
        return false;
    };
    if !matches!(interval_unit, b'h' | b'd' | b'w' | b'm' | b'y') {
        return false;
    }
    let remainder = &value[interval_digits + 1..];
    if remainder.is_empty() {
        return true;
    }
    let Some(deadline) = remainder.strip_prefix('/') else {
        return false;
    };
    let deadline_digits = deadline.bytes().take_while(u8::is_ascii_digit).count();
    if deadline_digits == 0 {
        return false;
    }
    let deadline_unit = &deadline[deadline_digits..];
    deadline_unit.is_empty()
        || (deadline_unit.len() == 1
            && matches!(
                deadline_unit.as_bytes()[0],
                b'h' | b'd' | b'w' | b'm' | b'y'
            ))
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

fn planning_warning(
    headline: &Headline,
    keyword: &str,
    timestamp: Option<Timestamp>,
) -> Option<NaiveDate> {
    timestamp
        .and_then(|timestamp| {
            let value = timestamp.warning_value()?;
            let unit = timestamp.warning_unit()?;
            let date = timestamp_to_date(timestamp)?.date;
            subtract_warning(date, value, unit)
        })
        .or_else(|| {
            headline
                .raw()
                .lines()
                .take_while(|line| {
                    line.chars()
                        .take_while(|character| *character == '*')
                        .count()
                        <= headline.level()
                })
                .find_map(|line| parse_planning_warning(line, keyword))
        })
}

fn subtract_warning(date: NaiveDate, value: u32, unit: TimeUnit) -> Option<NaiveDate> {
    match unit {
        TimeUnit::Hour => Some(date),
        TimeUnit::Day => date.checked_sub_signed(Duration::days(i64::from(value))),
        TimeUnit::Week => date.checked_sub_signed(Duration::weeks(i64::from(value))),
        TimeUnit::Month => date.checked_sub_months(Months::new(value)),
        TimeUnit::Year => value
            .checked_mul(12)
            .and_then(|months| date.checked_sub_months(Months::new(months))),
    }
}

fn parse_planning_warning(line: &str, keyword: &str) -> Option<NaiveDate> {
    let value = line
        .trim_start()
        .strip_prefix(&format!("{keyword}:"))?
        .trim_start();
    let opener = value.chars().next()?;
    if opener != '<' && opener != '[' {
        return None;
    }
    let closer = if opener == '<' { '>' } else { ']' };
    let end = value.find(closer)?;
    let timestamp = &value[1..end];
    let date = NaiveDate::parse_from_str(timestamp.get(..10)?, "%Y-%m-%d").ok()?;
    timestamp
        .split_whitespace()
        .find_map(parse_warning_token)
        .and_then(|(value, unit)| subtract_warning(date, value, unit))
}

fn parse_warning_token(token: &str) -> Option<(u32, TimeUnit)> {
    let value = token
        .strip_prefix("--")
        .or_else(|| token.strip_prefix('-'))?;
    let digits = value.bytes().take_while(u8::is_ascii_digit).count();
    if digits == 0 {
        return None;
    }
    let unit = match value.as_bytes().get(digits)? {
        b'h' => TimeUnit::Hour,
        b'd' => TimeUnit::Day,
        b'w' => TimeUnit::Week,
        b'm' => TimeUnit::Month,
        b'y' => TimeUnit::Year,
        _ => return None,
    };
    Some((value[..digits].parse().ok()?, unit))
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
            apply_negation(task.path() == *value, *negated)
        }
        FilterExpression::State { value, negated } => apply_negation(
            task.state_name()
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
        FilterExpression::HasAddressLink { negated } => {
            apply_negation(!task.address_links.is_empty(), *negated)
        }
        FilterExpression::Date {
            field,
            relation,
            interval,
        } => {
            let dates = dates_for_field(task, *field, *relation, *interval);
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

fn dates_for_field(
    task: &FilterTask,
    field: FilterDateField,
    relation: FilterRelation,
    interval: FilterInterval,
) -> Vec<FilterDate> {
    match field {
        FilterDateField::Scheduled => {
            adjusted_planning_date(task.scheduled, task.scheduled_warning, relation, interval)
                .into_iter()
                .collect()
        }
        FilterDateField::Deadline => {
            adjusted_planning_date(task.deadline, task.deadline_warning, relation, interval)
                .into_iter()
                .collect()
        }
        FilterDateField::Closed => task.closed.into_iter().collect(),
        FilterDateField::Created => task.created.into_iter().collect(),
        FilterDateField::Event => task.events.clone(),
    }
}

fn adjusted_planning_date(
    date: Option<FilterDate>,
    warning: Option<NaiveDate>,
    relation: FilterRelation,
    interval: FilterInterval,
) -> Option<FilterDate> {
    let mut date = date?;
    let today_interval = matches!(interval.unit, FilterIntervalUnit::Now)
        || (matches!(interval.unit, FilterIntervalUnit::Day) && interval.value == 0);
    if today_interval && matches!(relation, FilterRelation::Lt | FilterRelation::Le) && date.active
    {
        if let Some(warning) = warning {
            date.date = warning;
        }
    }
    Some(date)
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
            // 修改时间缺失始终置末，不随升降序反转，也不使用创建时间替代。
            if order.field == FilterSortField::Modified {
                match (left.modified_at, right.modified_at) {
                    (Some(_), None) => return Ordering::Less,
                    (None, Some(_)) => return Ordering::Greater,
                    _ => {}
                }
            }
            let result = compare_sort(left, right, order.field);
            if result != Ordering::Equal {
                return if order.descending {
                    result.reverse()
                } else {
                    result
                };
            }
        }
        left.path()
            .cmp(right.path())
            .then(left.byte_offset.cmp(&right.byte_offset))
    });
}

fn compare_sort(left: &FilterTask, right: &FilterTask, field: FilterSortField) -> Ordering {
    match field {
        FilterSortField::Book => left.path().cmp(right.path()),
        FilterSortField::Title => left.title.cmp(&right.title),
        FilterSortField::Priority => left.priority.cmp(&right.priority),
        FilterSortField::State => left.state_name().cmp(&right.state_name()),
        FilterSortField::Scheduled => left.scheduled.cmp(&right.scheduled),
        FilterSortField::Deadline => left.deadline.cmp(&right.deadline),
        FilterSortField::Closed => left.closed.cmp(&right.closed),
        FilterSortField::Created => left.created_at.cmp(&right.created_at),
        FilterSortField::Modified => left.modified_at.cmp(&right.modified_at),
        FilterSortField::Event => left.events.first().cmp(&right.events.first()),
        FilterSortField::Position => left
            .path()
            .cmp(right.path())
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
    if token == "has.address" {
        return Some(FilterExpression::HasAddressLink { negated });
    }
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
        "modified" => FilterSortField::Modified,
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
    fn task_done_keywords_follow_effective_file_configuration() {
        let mut repo = OrgRepo::new("/unused/done-keywords".into()).unwrap();
        repo.id = "repo".into();
        for (source, setup, expected) in [
            ("* TODO Task\n", "", vec!["DONE"]),
            (
                "#+TODO: OPEN | FINISHED(f!) CANCELLED(c)\n#+TODO: NEXT | ACCEPTED\n* OPEN Task\n",
                "",
                vec!["FINISHED", "CANCELLED", "ACCEPTED"],
            ),
            ("* NEXT Task\n", "#+TODO: NEXT | CLOSED", vec!["CLOSED"]),
            ("#+TODO:\n* Plain\n", "", vec![]),
        ] {
            let file = OrgFile::with_todo_defaults_and_setup(
                repo.id.clone(),
                "tasks.org".into(),
                source.as_bytes().to_vec(),
                crate::TodoConfig::default(),
                setup.into(),
            )
            .unwrap();
            assert_eq!(tasks_from_file(&repo, &file).len(), 1);
            assert_eq!(file.todo.done_keywords, expected, "{source}");
            assert_eq!(file.source_bytes(), source.as_bytes());
        }
    }

    #[test]
    fn modified_sort_keeps_missing_values_last_and_uses_source_order_for_ties() {
        let mut file = OrgFile::new("repo".into(), "notes.org".into(),
            b"* Missing\n:PROPERTIES:\n:CREATED: [2030-01-01 Tue 12:00]\n:END:\n* Old\n:PROPERTIES:\n:LAST_MODIFIED: [2026-11-08 Sun 09:00]\n:END:\n* New\n:PROPERTIES:\n:last_modified: [2026-11-09 Mon 10:00]\n:END:\n* Same time\n:PROPERTIES:\n:LAST_MODIFIED: [2026-11-09 Mon 10:00]\n:END:\n".to_vec()).unwrap();
        // 文件 mtime 即使可用，也不能为缺失任务属性补值或参与排序。
        file.modified_at = Some(999_999_999_999);
        let repo = OrgRepo::new("/tmp/modified-sort".into()).unwrap();
        let mut tasks = tasks_from_file(&repo, &file);
        assert!(tasks[0].modified_at().is_none());
        Filter::parse(".o.modified").filter_tasks(&mut tasks);
        assert_eq!(
            tasks.iter().map(FilterTask::title).collect::<Vec<_>>(),
            ["New", "Same time", "Old", "Missing"]
        );
        Filter::parse("o.modified").filter_tasks(&mut tasks);
        assert_eq!(
            tasks.iter().map(FilterTask::title).collect::<Vec<_>>(),
            ["Old", "New", "Same time", "Missing"]
        );
    }

    #[test]
    fn created_window_matches_three_local_calendar_days() {
        let file = OrgFile::new(
            "repo".into(),
            "tasks.org".into(),
            b"* TODO Task\n:PROPERTIES:\n:CREATED: [2026-11-08 Sun 12:00]\n:END:\n".to_vec(),
        )
        .unwrap();
        let repo = OrgRepo::new("/tmp/created-window".into()).unwrap();
        let tasks = tasks_from_file(&repo, &file);
        let filter = Filter::parse("cr.ge.-2d cr.le.today");
        assert!(filter.matches_at(&tasks[0], NaiveDate::from_ymd_opt(2026, 11, 10).unwrap()));
        assert!(!filter.matches_at(&tasks[0], NaiveDate::from_ymd_opt(2026, 11, 11).unwrap()));
    }

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

    #[tokio::test]
    async fn filters_tasks_with_reference_state_tag_and_date_semantics() {
        let file = OrgFile::new("repo".into(), "work.org".into(), b"* TODO Parent :work:\n** DONE Child :home:\nSCHEDULED: <2024-01-03 Wed>\n* TODO Other\n* Plain heading\n".to_vec()).unwrap();
        let repository = crate::model::test_support::with_files(
            OrgRepo {
                id: "repo".into(),
                root_directory: "/tmp".into(),
                todo_defaults: crate::TodoConfig::default(),
            },
            vec![file],
            Default::default(),
        );
        let tasks = tasks_from_repo(&repository).await.unwrap();
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

    #[tokio::test]
    async fn file_level_cancel_state_is_done_in_task_projection() {
        let file = OrgFile::with_todo_defaults(
            "repo".into(),
            "work.org".into(),
            b"#+TODO: TODO | DONE CNCL\n* CNCL Cancelled\n".to_vec(),
            crate::TodoConfig::default(),
        )
        .unwrap();
        let repository = crate::model::test_support::with_files(
            OrgRepo {
                id: "repo".into(),
                root_directory: "/tmp".into(),
                todo_defaults: crate::TodoConfig::default(),
            },
            vec![file],
            Default::default(),
        );
        let task = tasks_from_repo(&repository).await.unwrap().pop().unwrap();
        assert_eq!(task.state_name(), Some("CNCL"));
        assert_eq!(task.state_type, FilterStateType::Done);
    }

    #[tokio::test]
    async fn is_done_follows_each_files_in_buffer_configuration() {
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
                true,
            ),
            ("cleared.org", "#+TODO:\n* CNCL Plain\n", false),
            ("global.org", "* CNCL Done by default\n", true),
            ("plain.org", "* No state\n", false),
        ];
        let repository = crate::model::test_support::with_files(
            OrgRepo {
                id: "repo".into(),
                root_directory: "/tmp".into(),
                todo_defaults: defaults.clone(),
            },
            sources
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
            Default::default(),
        );
        let tasks = tasks_from_repo(&repository).await.unwrap();
        for (path, _, expected) in sources {
            let task = tasks.iter().find(|task| task.path() == path).unwrap();
            assert_eq!(task.is_done(), expected, "{path}");
            assert_eq!(Filter::parse("it.done").matches(task), task.is_done());
        }
    }

    #[tokio::test]
    async fn projects_scheduled_timestamp_with_repeater() {
        let file = OrgFile::new(
            "repo".into(),
            "work.org".into(),
            b"* TODO Repeated\nSCHEDULED: <2026-09-27 Sun .+4w/5w>\n".to_vec(),
        )
        .unwrap();
        let repository = crate::model::test_support::with_files(
            OrgRepo {
                id: "repo".into(),
                root_directory: "/tmp".into(),
                todo_defaults: crate::TodoConfig::default(),
            },
            vec![file],
            Default::default(),
        );
        let task = tasks_from_repo(&repository).await.unwrap().pop().unwrap();
        assert_eq!(
            task.scheduled,
            Some(FilterDate {
                date: NaiveDate::from_ymd_opt(2026, 9, 27).unwrap(),
                active: true,
            })
        );
    }

    #[tokio::test]
    async fn deadline_warning_period_matches_today_without_changing_display_date() {
        let file = OrgFile::new(
            "repo".into(),
            "mortgage.org".into(),
            "* TODO 中信银行-房贷（春风湖滨） 利率(2.90)\nDEADLINE: <2026-11-10 Mon -2d>\n"
                .as_bytes()
                .to_vec(),
        )
        .unwrap();
        let repository = crate::model::test_support::with_files(
            OrgRepo {
                id: "repo".into(),
                root_directory: "/tmp".into(),
                todo_defaults: crate::TodoConfig::default(),
            },
            vec![file],
            Default::default(),
        );
        let task = tasks_from_repo(&repository).await.unwrap().pop().unwrap();
        assert_eq!(
            task.deadline.unwrap().date,
            NaiveDate::from_ymd_opt(2026, 11, 10).unwrap()
        );
        assert_eq!(
            task.deadline_warning,
            Some(NaiveDate::from_ymd_opt(2026, 11, 8).unwrap())
        );
        let today = NaiveDate::from_ymd_opt(2026, 11, 8).unwrap();
        assert!(Filter::parse("d.le.today").matches_at(&task, today));
        assert!(
            !Filter::parse("d.le.today")
                .matches_at(&task, NaiveDate::from_ymd_opt(2026, 11, 7).unwrap())
        );
        assert!(!Filter::parse("d.le.yesterday").matches_at(&task, today));
        assert!(Filter::parse("d.ge.tomorrow").matches_at(&task, today));
        let badge_filter = Filter::parse("it.todo d.lt.tomorrow");
        assert!(!badge_filter.matches_at(&task, today));
        assert!(!badge_filter.matches_at(&task, NaiveDate::from_ymd_opt(2026, 11, 9).unwrap()));
        assert!(badge_filter.matches_at(&task, NaiveDate::from_ymd_opt(2026, 11, 10).unwrap()));
        assert!(badge_filter.matches_at(&task, NaiveDate::from_ymd_opt(2026, 11, 11).unwrap()));
    }
}
