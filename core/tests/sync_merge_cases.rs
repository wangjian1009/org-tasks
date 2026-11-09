//! 用例直接调用纯内容 merge；驱动不创建仓库、异步运行时或网络服务。
#[path = "sync_merge_support/check.rs"]
mod check;
#[path = "sync_merge_support/fixture.rs"]
mod fixture;

use clap::Parser;
use fixture::{Case, Data};
use org_tasks_core::{OrgFile, merge};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

fn ensure(condition: bool, message: impl Into<String>) -> Result<()> {
    if condition {
        Ok(())
    } else {
        Err(message.into().into())
    }
}

#[derive(Parser)]
#[command(about = "直接调用 merge 验证三份 Org 内容；不启动服务，失败时保留输入、原始结果与可读差异", long_about = None)]
struct Args {
    /// 只执行指定 group/case，可重复；未知用例报错
    #[arg(long = "case")]
    cases: Vec<String>,
    /// 只执行指定测试组，可重复；与 --case 同时提供时取交集
    #[arg(long = "group")]
    groups: Vec<String>,
    /// 列出筛选后的用例及目的，不执行合并
    #[arg(long)]
    list: bool,
    /// 用例根目录
    #[arg(long, default_value = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/sync_merge_cases"))]
    cases_dir: PathBuf,
    /// 将用例结果和失败现场路径写入 JSON 报告
    #[arg(long)]
    report: Option<PathBuf>,
    #[arg(long, hide = true)]
    nocapture: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CaseResult {
    case: String,
    passed: bool,
    error: Option<String>,
    artifacts: Option<String>,
}

fn main() {
    if let Err(error) = main_result() {
        eprintln!("ERROR {error}");
        std::process::exit(1);
    }
}

fn main_result() -> Result<()> {
    let args = Args::parse();
    let mut cases = Vec::new();
    for group in std::fs::read_dir(&args.cases_dir)? {
        let group = group?;
        ensure(!group.file_type()?.is_symlink(), "测试组不允许符号链接")?;
        if !group.file_type()?.is_dir() {
            continue;
        }
        for entry in std::fs::read_dir(group.path())? {
            let entry = entry?;
            ensure(!entry.file_type()?.is_symlink(), "用例不允许符号链接")?;
            if entry.file_type()?.is_dir() && entry.path().join("case.json").is_file() {
                let name = format!(
                    "{}/{}",
                    group.file_name().to_string_lossy(),
                    entry.file_name().to_string_lossy()
                );
                cases.push((name, entry.path()));
            }
        }
    }
    cases.sort();
    for name in &args.cases {
        ensure(
            cases.iter().any(|(case, _)| case == name),
            format!("未知用例: {name}"),
        )?;
    }
    for group in &args.groups {
        ensure(
            cases
                .iter()
                .any(|(name, _)| name.split('/').next() == Some(group)),
            format!("未知测试组: {group}"),
        )?;
    }
    cases.retain(|(name, _)| {
        (args.cases.is_empty() || args.cases.contains(name))
            && (args.groups.is_empty()
                || args
                    .groups
                    .iter()
                    .any(|group| name.starts_with(&format!("{group}/"))))
    });
    ensure(!cases.is_empty(), "没有匹配用例")?;
    let mut results = Vec::new();
    for (number, (name, path)) in cases.iter().enumerate() {
        let parsed = read_case(path);
        if args.list {
            println!("{name}\t{}", parsed?.purpose);
            continue;
        }
        let root = std::env::temp_dir().join(format!(
            "org-merge-case-{}-{}-{number}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()
        ));
        std::fs::create_dir_all(&root)?;
        let result = parsed.and_then(|case| run_case(path, &root, case));
        let error = result.err().map(|error| error.to_string());
        let passed = error.is_none();
        let artifacts = if passed {
            std::fs::remove_dir_all(&root)?;
            println!("PASS {name}");
            None
        } else {
            eprintln!(
                "FAIL {name}: {}\n  失败现场: {}",
                error.as_deref().unwrap(),
                root.display()
            );
            Some(root.to_string_lossy().into_owned())
        };
        results.push(CaseResult {
            case: name.clone(),
            passed,
            error,
            artifacts,
        });
    }
    if args.list {
        return Ok(());
    }
    if let Some(path) = args.report {
        std::fs::write(path, serde_json::to_vec_pretty(&results)?)?;
    }
    let passed = results.iter().filter(|result| result.passed).count();
    println!("{passed}/{} 用例通过", results.len());
    ensure(passed == results.len(), "存在失败用例")
}

fn read_case(path: &Path) -> Result<Case> {
    let case: Case = serde_json::from_slice(&fixture::read(path, "case.json")?)?;
    ensure(case.format_version == 2, "不支持的用例版本")?;
    ensure(
        !case.purpose.trim().is_empty() && !case.rounds.is_empty(),
        "用例目的和轮次不能为空",
    )?;
    for (i, round) in case.rounds.iter().enumerate() {
        ensure(!round.label.is_empty(), "合并轮次缺少说明")?;
        let expected = &round.expected;
        let count = usize::from(expected.content.is_some())
            + usize::from(expected.same_bytes_as_round.is_some())
            + usize::from(expected.error.is_some());
        ensure(count == 1, "预期内容、原始字节引用、错误只能指定一项")?;
        let mut references = Vec::new();
        if let Some(reference) = expected.same_bytes_as_round {
            references.push(reference);
        }
        for data in [&round.input.base, &round.input.local, &round.input.remote] {
            if let Data::Previous(reference) = data {
                references.push(reference.round);
            }
        }
        for reference in references {
            ensure(
                reference > 0 && reference <= i,
                "只能引用当前轮次之前的成功合并结果",
            )?;
            ensure(
                case.rounds[reference - 1].expected.error.is_none(),
                "不能引用预期失败的合并结果",
            )?;
        }
        if let Some(error) = &expected.error {
            ensure(
                !error.is_empty() && round.inspect.is_empty(),
                "错误预期不能为空或携带输出结构断言",
            )?;
        }
    }
    Ok(case)
}

fn data(case: &Path, source: &Data, previous: &[Option<Vec<u8>>]) -> Result<Vec<u8>> {
    match source {
        Data::File(path) => fixture::read(case, path),
        Data::Previous(reference) => previous[reference.round - 1]
            .clone()
            .ok_or_else(|| "引用的合并结果不存在".into()),
    }
}

fn run_case(case: &Path, artifacts: &Path, spec: Case) -> Result<()> {
    std::fs::copy(case.join("case.json"), artifacts.join("case.json"))?;
    let mut previous = Vec::new();
    for (i, round) in spec.rounds.iter().enumerate() {
        let output = artifacts.join(format!("round-{:02}", i + 1));
        std::fs::create_dir_all(&output)?;
        let result = (|| -> Result<Option<Vec<u8>>> {
            let base = data(case, &round.input.base, &previous)?;
            let local = data(case, &round.input.local, &previous)?;
            let remote = data(case, &round.input.remote, &previous)?;
            for (name, bytes) in [
                ("base.org", &base),
                ("local.org", &local),
                ("remote.org", &remote),
            ] {
                std::fs::write(output.join(name), bytes)?;
            }
            let result = merge(&base, &local, &remote);
            if let Some(error) = &round.expected.error {
                let actual = result.err().ok_or("预期合并报错，但实际成功")?.to_string();
                std::fs::write(output.join("error.txt"), &actual)?;
                ensure(actual.contains(error), format!("合并错误不同: {actual}"))?;
                return Ok(None);
            }
            let actual = result?;
            std::fs::write(output.join("actual.org"), &actual)?;
            std::fs::write(output.join("readable.org"), check::readable(&actual)?)?;
            let (expected, normalize) = if let Some(path) = &round.expected.content {
                (fixture::read(case, path)?, true)
            } else {
                (
                    previous[round.expected.same_bytes_as_round.unwrap() - 1]
                        .clone()
                        .ok_or("引用的结果不存在")?,
                    false,
                )
            };
            std::fs::write(output.join("expected.org"), &expected)?;
            check::compare(&round.label, &actual, &expected, normalize)?;
            let file = OrgFile::new("merge".into(), "content.org".into(), actual.clone())?;
            check::inspect(&file, case, &round.inspect)?;
            Ok(Some(actual))
        })();
        previous
            .push(result.map_err(|error| format!("第 {} 轮（{}）: {error}", i + 1, round.label))?);
    }
    Ok(())
}
