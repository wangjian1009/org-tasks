//! 文件任务内的读取入口；请求缓存只共享不可变读取结果，不在调度器预读文件。
use super::*;
use std::sync::{Arc, Mutex};
use tokio::sync::OnceCell;

pub(super) struct FileInput {
    pub(super) disk: PathBuf,
    pub(super) original: Option<Vec<u8>>,
    pub(super) stamp: Option<FileStamp>,
    pub(super) setup: String,
    pub(super) ignored: bool,
    pub(super) new_file: Option<(String, String)>,
    pub(super) path: String,
}

impl FileInput {
    pub(super) fn load(self, repo: &OrgRepo) -> Result<WorkingFile, CoreError> {
        let mut file = repo.parse_file_with_setup(
            self.path,
            self.original.clone().unwrap_or_default(),
            self.setup,
        )?;
        file.modified_at = self.stamp.as_ref().and_then(stamp_timestamp);
        file.scan_ignored = self.ignored;
        let before_metadata = self.original.as_ref().map(|_| file.metadata(self.ignored));
        Ok(WorkingFile {
            disk: self.disk,
            exists: self.original.is_some(),
            original: self.original,
            file,
            stamp: self.stamp,
            before_metadata,
            new_file: self.new_file,
        })
    }
}

#[derive(Clone)]
struct ReadSnapshot {
    disk: PathBuf,
    original: Option<Vec<u8>>,
    stamp: Option<FileStamp>,
}

type ReadCell = Arc<OnceCell<Result<ReadSnapshot, CoreError>>>;

#[derive(Clone, Default)]
pub(super) struct ReadCache(Arc<Mutex<BTreeMap<FileKey, ReadCell>>>);

impl ReadCache {
    async fn read(&self, repo: &OrgRepo, path: &str) -> Result<ReadSnapshot, CoreError> {
        super::super::validate_relative_path(path)?;
        let cell = self
            .0
            .lock()
            .map_err(|_| CoreError::InvalidState("文件读取缓存不可用"))?
            .entry((repo.id.clone(), path.into()))
            .or_default()
            .clone();
        cell.get_or_init(|| async {
            let root = Path::new(&repo.root_directory);
            let _guard = super::super::access::enter(root, &repo.id).await?;
            let disk = checked_disk(root, path).await?;
            let stamp = file_stamp(&disk).await?;
            let original = read_optional(&disk).await?;
            if file_stamp(&disk).await? != stamp {
                return Err(CoreError::InvalidState("读取期间任务文件已被外部修改"));
            }
            Ok(ReadSnapshot {
                disk,
                original,
                stamp,
            })
        })
        .await
        .clone()
    }

    async fn bytes(&self, repo: &OrgRepo, path: &str) -> Result<Option<Vec<u8>>, CoreError> {
        Ok(self.read(repo, path).await?.original)
    }
}

pub(super) struct FileLoadSpec {
    pub repo: OrgRepo,
    pub path: String,
    pub versions: Vec<String>,
    pub new_files: Vec<TaskFileNew>,
    pub export_records: bool,
    pub full_file: bool,
    pub cache: ReadCache,
}

pub(super) async fn load(
    spec: &FileLoadSpec,
) -> Result<(WorkingFile, ReadDependencies), CoreError> {
    if spec
        .new_files
        .iter()
        .any(|file| !file.path.titles.is_empty())
    {
        return Err(CoreError::InvalidInput("新文件必须使用文件根路径"));
    }
    let source = spec.cache.read(&spec.repo, &spec.path).await?;
    let actual = source
        .original
        .as_ref()
        .map(|bytes| LocalFileVersion::from_bytes(bytes).content_hash);
    if spec
        .versions
        .iter()
        .any(|expected| Some(expected) != actual.as_ref())
    {
        return Err(CoreError::InvalidState("任务文件版本已变化，请刷新后重试"));
    }
    let root = PathBuf::from(&spec.repo.root_directory);
    let mut read_cache = BTreeMap::new();
    read_cache.insert(spec.path.clone(), source.original.clone());
    let rules_path = super::super::task_scan::TASK_SCAN_RULES_PATH;
    let rules_bytes = spec.cache.bytes(&spec.repo, rules_path).await?;
    read_cache.insert(rules_path.into(), rules_bytes.clone());
    let rules = match rules_bytes {
        Some(bytes) => TaskScanRules::parse(
            std::str::from_utf8(&bytes)
                .map_err(|_| CoreError::Store(".orgzlyignore 必须是 UTF-8".into()))?,
        )?,
        None => TaskScanRules::default(),
    };
    let settings = setup(
        spec,
        &source.original.clone().unwrap_or_default(),
        &mut read_cache,
    )
    .await?;
    let mut input = FileInput {
        disk: source.disk,
        original: source.original,
        stamp: source.stamp,
        setup: settings,
        ignored: rules.excludes(&spec.path),
        new_file: None,
        path: spec.path.clone(),
    };
    for new_file in &spec.new_files {
        if input.original.is_some() || input.new_file.is_some() {
            return Err(CoreError::InvalidState("目标文件已存在，不能覆盖"));
        }
        let template = if !new_file.template_content.is_empty() || new_file.template_path.is_empty()
        {
            new_file.template_content.clone()
        } else {
            super::super::validate_relative_path(&new_file.template_path)?;
            if new_file
                .template_path
                .split('/')
                .any(|part| part == ".sync")
            {
                return Err(CoreError::InvalidInput("模板不能位于控制目录"));
            }
            let bytes = cached_bytes(spec, &new_file.template_path, &mut read_cache)
                .await?
                .ok_or(CoreError::InvalidInput("模板文件不存在"))?;
            String::from_utf8(bytes)
                .map_err(|_| CoreError::InvalidInput("模板必须是 UTF-8 文本"))?
        };
        let has_setup = orgize::Org::parse(&template)
            .document()
            .keywords()
            .any(|keyword| keyword.key().eq_ignore_ascii_case("SETUPFILE"));
        let setup_exists = has_setup
            && cached_bytes(spec, ".setup.org", &mut read_cache)
                .await?
                .is_some();
        let setup_path = format!(
            "{}.setup.org",
            "../".repeat(spec.path.split('/').count() - 1)
        );
        let source = super::super::file_template::render(
            &template,
            &new_file.arguments,
            setup_exists.then_some(setup_path.as_str()),
        )?;
        let settings = setup(spec, source.as_bytes(), &mut read_cache).await?;
        spec.repo.parse_file_with_setup(
            spec.path.clone(),
            source.as_bytes().to_vec(),
            settings.clone(),
        )?;
        input.new_file = Some((source, settings));
    }
    let dependencies = read_cache
        .into_iter()
        .filter(|(path, _)| path != &spec.path)
        .map(|(path, original)| (root.clone(), path, original))
        .collect();
    Ok((input.load(&spec.repo)?, dependencies))
}

async fn setup(
    spec: &FileLoadSpec,
    source: &[u8],
    cache: &mut BTreeMap<String, Option<Vec<u8>>>,
) -> Result<String, CoreError> {
    super::super::service::load_setup_settings_with_reader(&spec.path, source, cache, |path| {
        let reader = spec.cache.clone();
        let repo = spec.repo.clone();
        async move { reader.bytes(&repo, &path).await }
    })
    .await
}

async fn cached_bytes(
    spec: &FileLoadSpec,
    path: &str,
    cache: &mut BTreeMap<String, Option<Vec<u8>>>,
) -> Result<Option<Vec<u8>>, CoreError> {
    if let Some(bytes) = cache.get(path) {
        return Ok(bytes.clone());
    }
    let bytes = spec.cache.bytes(&spec.repo, path).await?;
    cache.insert(path.into(), bytes.clone());
    Ok(bytes)
}
