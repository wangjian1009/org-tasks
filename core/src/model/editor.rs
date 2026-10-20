use super::OrgFile;
use crate::CoreError;
use serde::{Deserialize, Serialize};

pub type SourcePositionError = CoreError;
pub type SourceRangeError = CoreError;
pub type OrgFileEditError = CoreError;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourcePosition {
    pub line: u32,
    pub column: u32,
    pub byte_offset: u64,
}

impl SourcePosition {
    pub fn new(line: u32, column: u32, byte_offset: u64) -> Result<Self, SourcePositionError> {
        if line == 0 {
            return Err(CoreError::InvalidInput("源位置行号必须从 1 开始"));
        }
        Ok(Self {
            line,
            column,
            byte_offset,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceRange {
    pub start: SourcePosition,
    pub end: SourcePosition,
}

impl SourceRange {
    pub fn new(start: SourcePosition, end: SourcePosition) -> Result<Self, SourceRangeError> {
        if start.byte_offset > end.byte_offset {
            return Err(CoreError::InvalidInput("源范围起点不能位于终点之后"));
        }
        Ok(Self { start, end })
    }

    pub fn contains(&self, position: &SourcePosition) -> bool {
        self.start.byte_offset <= position.byte_offset
            && position.byte_offset < self.end.byte_offset
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OrgFileEdit {
    ReplaceRange {
        target: SourceRange,
        content: Vec<u8>,
    },
    InsertAt {
        anchor: SourcePosition,
        content: Vec<u8>,
    },
}

pub fn serialize_file(file: &OrgFile) -> &[u8] {
    file.source_bytes()
}

pub fn apply_edit(file: &mut OrgFile, edit: OrgFileEdit) -> Result<(), OrgFileEditError> {
    let mut updated = file.clone();
    apply_edit_inner(&mut updated, edit)?;
    *file = updated;
    Ok(())
}

fn apply_edit_inner(file: &mut OrgFile, edit: OrgFileEdit) -> Result<(), OrgFileEditError> {
    match edit {
        OrgFileEdit::ReplaceRange { target, content } => {
            validate_content(&content)?;
            let start = offset(target.start)?;
            let end = offset(target.end)?;
            validate_position(file.source_bytes(), start, target.start)?;
            validate_position(file.source_bytes(), end, target.end)?;
            if start > end {
                return Err(CoreError::InvalidInput("编辑范围起点不能位于终点之后"));
            }
            file.source_bytes.splice(start..end, content);
        }
        OrgFileEdit::InsertAt { anchor, content } => {
            validate_content(&content)?;
            let offset = offset(anchor)?;
            validate_position(file.source_bytes(), offset, anchor)?;
            file.source_bytes.splice(offset..offset, content);
        }
    }
    file.reparse()
}

fn validate_content(content: &[u8]) -> Result<(), CoreError> {
    if content.is_empty() {
        return Err(CoreError::InvalidInput("编辑内容不能为空"));
    }
    std::str::from_utf8(content)
        .map_err(|_| CoreError::InvalidInput("编辑内容必须是 UTF-8 编码"))?;
    Ok(())
}

fn offset(position: SourcePosition) -> Result<usize, CoreError> {
    usize::try_from(position.byte_offset)
        .map_err(|_| CoreError::InvalidInput("源位置字节偏移超出文件范围"))
}

fn validate_position(
    source: &[u8],
    offset: usize,
    position: SourcePosition,
) -> Result<(), CoreError> {
    if offset > source.len() || position_at(source, offset) != position {
        return Err(CoreError::InvalidInput("编辑位置不属于当前文件快照"));
    }
    Ok(())
}

pub(super) fn position_at(source: &[u8], byte_offset: usize) -> SourcePosition {
    let mut line = 1;
    let mut column = 0;
    for byte in &source[..byte_offset] {
        if *byte == b'\n' {
            line += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    SourcePosition {
        line,
        column,
        byte_offset: byte_offset as u64,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replacement_preserves_unmodified_bytes() {
        let mut file =
            OrgFile::new("repo".into(), "inbox.org".into(), b"a\r\n\r\nb".to_vec()).unwrap();
        apply_edit(
            &mut file,
            OrgFileEdit::ReplaceRange {
                target: SourceRange::new(
                    SourcePosition::new(1, 0, 0).unwrap(),
                    SourcePosition::new(1, 1, 1).unwrap(),
                )
                .unwrap(),
                content: b"alpha".to_vec(),
            },
        )
        .unwrap();
        assert_eq!(serialize_file(&file), b"alpha\r\n\r\nb");
        assert_eq!(file.syntax().to_org().as_bytes(), b"alpha\r\n\r\nb");
    }
}
