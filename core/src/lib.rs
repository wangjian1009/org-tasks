//! 平台与持久化无关的 Org Tasks 领域核心。

use std::fmt::{Display, Formatter};

pub type TimestampMs = i64;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CoreError {
    InvalidInput(&'static str),
    Store(String),
    InvalidState(&'static str),
}

impl Display for CoreError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidInput(message) | Self::InvalidState(message) => {
                formatter.write_str(message)
            }
            Self::Store(message) => write!(formatter, "存储操作失败: {message}"),
        }
    }
}

impl std::error::Error for CoreError {}

pub mod model;
pub mod webdav;

pub use model::*;
