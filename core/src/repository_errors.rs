//! 每个 Workspace 的仓库错误与观察顺序。
use std::collections::BTreeMap;
use tokio::sync::{mpsc, oneshot};

use crate::{CoreError, NotificationCenter};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RepositoryRootObservation {
    pub(crate) directory: String,
    pub(crate) epoch: u64,
    pub(crate) revision: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RepositoryError {
    RootMissing,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum RepositoryErrorKind {
    RootMissing,
}

impl RepositoryError {
    fn kind(self) -> RepositoryErrorKind {
        match self {
            Self::RootMissing => RepositoryErrorKind::RootMissing,
        }
    }
}

pub(crate) struct RepositoryErrorEntry {
    pub(crate) root_directory: String,
    pub(crate) error: RepositoryError,
}

pub(crate) struct RepositoryErrorSnapshot {
    pub(crate) revision: u64,
    pub(crate) errors: Vec<RepositoryErrorEntry>,
}

#[derive(Clone, Debug)]
pub(crate) struct RepositoryErrorManager(mpsc::UnboundedSender<Command>);

pub(crate) enum Command {
    Configure(BTreeMap<String, u64>),
    Observe(
        RepositoryRootObservation,
        RepositoryErrorKind,
        Option<RepositoryError>,
    ),
    Flush(oneshot::Sender<Result<(), CoreError>>),
    Stop,
}

#[derive(PartialEq, Eq)]
struct Observation {
    revision: u64,
    error: Option<RepositoryError>,
}

impl RepositoryErrorManager {
    pub(crate) fn new() -> (Self, mpsc::UnboundedReceiver<Command>) {
        let (sender, receiver) = mpsc::unbounded_channel();
        (Self(sender), receiver)
    }

    pub(crate) fn configure(&self, roots: BTreeMap<String, u64>) -> Result<(), CoreError> {
        self.send(Command::Configure(roots))
    }

    pub(crate) fn report(
        &self,
        observation: RepositoryRootObservation,
        error: RepositoryError,
    ) -> Result<(), CoreError> {
        self.send(Command::Observe(observation, error.kind(), Some(error)))
    }

    pub(crate) fn clear(
        &self,
        observation: RepositoryRootObservation,
        kind: RepositoryErrorKind,
    ) -> Result<(), CoreError> {
        self.send(Command::Observe(observation, kind, None))
    }

    pub(crate) async fn flush(&self) -> Result<(), CoreError> {
        let (done, received) = oneshot::channel();
        self.send(Command::Flush(done))?;
        received
            .await
            .map_err(|_| CoreError::InvalidState("仓库错误处理任务已停止"))?
    }

    pub(crate) fn stop(&self) {
        let _ = self.send(Command::Stop);
    }

    fn send(&self, command: Command) -> Result<(), CoreError> {
        self.0
            .send(command)
            .map_err(|_| CoreError::InvalidState("仓库错误处理任务已停止"))
    }

    pub(crate) async fn process(
        mut commands: mpsc::UnboundedReceiver<Command>,
        center: NotificationCenter,
    ) {
        let mut configured = BTreeMap::new();
        let mut observed = BTreeMap::<(String, RepositoryErrorKind), Observation>::new();
        let mut revision = 0;
        let mut result = Ok(());
        while let Some(command) = commands.recv().await {
            let changed = match command {
                Command::Configure(roots) => {
                    let mut removed_error = false;
                    observed.retain(|(root, _), observation| {
                        let keep = roots.get(root) == configured.get(root);
                        removed_error |= !keep && observation.error.is_some();
                        keep
                    });
                    configured = roots;
                    removed_error
                }
                Command::Observe(stamp, kind, error) => {
                    if configured.get(&stamp.directory) != Some(&stamp.epoch) {
                        continue;
                    }
                    let key = (stamp.directory, kind);
                    let previous = observed.get(&key);
                    if previous.is_some_and(|value| value.revision >= stamp.revision) {
                        continue;
                    }
                    let changed = previous.and_then(|value| value.error) != error;
                    observed.insert(
                        key,
                        Observation {
                            revision: stamp.revision,
                            error,
                        },
                    );
                    changed
                }
                Command::Flush(done) => {
                    let _ = done.send(result.clone());
                    continue;
                }
                Command::Stop => break,
            };
            if changed {
                revision += 1;
                let errors = observed
                    .iter()
                    .filter_map(|((root_directory, _), observation)| {
                        Some(RepositoryErrorEntry {
                            root_directory: root_directory.clone(),
                            error: observation.error?,
                        })
                    })
                    .collect();
                result = center.repository_errors(RepositoryErrorSnapshot { revision, errors });
            }
        }
    }
}

/// 仅把根目录本身不存在视为缺失；文件、权限和身份错误走原错误路径。
pub(crate) async fn root_missing(root: &str) -> bool {
    tokio::fs::metadata(root)
        .await
        .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
}
