//! 平台与持久化无关的 Org Tasks 领域核心。

use std::fmt::{Display, Formatter};

pub type TimestampMs = i64;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoreError {
    InvalidInput(&'static str),
    Store(String),
    Preview {
        code: &'static str,
        message: &'static str,
    },
    InvalidState(&'static str),
}

impl Display for CoreError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidInput(message) | Self::InvalidState(message) => {
                formatter.write_str(message)
            }
            Self::Preview { message, .. } => formatter.write_str(message),
            Self::Store(message) => write!(formatter, "存储操作失败: {message}"),
        }
    }
}

impl std::error::Error for CoreError {}

mod filter;
mod merge;
pub mod model;
pub mod query;
pub mod http_server;
pub mod query_subscription;
pub use query_subscription::{QuerySubscription, QuerySubscriptionStart, QuerySubscriptionStatus};
pub use query::{QueryOrderPart, QueryOrderValue, QueryOrdering};
pub mod webdav;
pub mod workspace;
mod workspace_tasks;
pub use workspace::{OrgWorkspace, OrgWorkspaceValidationError};

pub use filter::{AddressLink, FilterDate, FilterStateType, FilterTask};
pub use merge::merge;
pub use model::*;
