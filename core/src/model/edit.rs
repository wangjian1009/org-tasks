use super::{
    OrgElement, OrgElementKind, OrgEntry, OrgEntryId, OrgFile, SourcePosition, SourceRange,
};
use crate::CoreError;

pub type OrgFileEditError = CoreError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OrgElementLocator {
    pub entry_id: OrgEntryId,
    pub source_range: SourceRange,
}

impl OrgElementLocator {
    pub fn for_element(entry_id: &OrgEntryId, element: &OrgElement) -> Self {
        Self {
            entry_id: entry_id.clone(),
            source_range: element.source_range,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OrgFileEdit {
    ReplaceElement {
        target: OrgElementLocator,
        kind: OrgElementKind,
        content: Vec<u8>,
    },
    InsertElement {
        entry_id: OrgEntryId,
        anchor: SourcePosition,
        kind: OrgElementKind,
        content: Vec<u8>,
    },
}

pub fn serialize_file(file: &OrgFile) -> &[u8] {
    file.source_bytes()
}

pub fn apply_edit(file: &mut OrgFile, edit: OrgFileEdit) -> Result<(), OrgFileEditError> {
    match edit {
        OrgFileEdit::ReplaceElement {
            target,
            kind,
            content,
        } => replace_element(file, target, kind, content),
        OrgFileEdit::InsertElement {
            entry_id,
            anchor,
            kind,
            content,
        } => insert_element(file, entry_id, anchor, kind, content),
    }
}

fn replace_element(
    file: &mut OrgFile,
    target: OrgElementLocator,
    kind: OrgElementKind,
    content: Vec<u8>,
) -> Result<(), CoreError> {
    validate_content(&content)?;
    let target_element = find_element_mut(&mut file.entries, &target)
        .ok_or(CoreError::InvalidInput("编辑目标元素不存在或已过期"))?;
    let old_range = target_element.source_range;
    let start = offset(old_range.start)?;
    let end = offset(old_range.end)?;
    if end > file.source_bytes.len() {
        return Err(CoreError::InvalidInput("编辑目标超出文件范围"));
    }
    target_element.kind = kind;
    file.source_bytes
        .splice(start..end, content.iter().copied());
    let new_end = start + content.len();
    rebase_ranges(
        &mut file.entries,
        EditRange::Replace {
            old: old_range,
            new_end,
        },
        &file.source_bytes,
    )
}

fn insert_element(
    file: &mut OrgFile,
    entry_id: OrgEntryId,
    anchor: SourcePosition,
    kind: OrgElementKind,
    content: Vec<u8>,
) -> Result<(), CoreError> {
    validate_content(&content)?;
    let anchor_offset = offset(anchor)?;
    if anchor_offset > file.source_bytes.len()
        || position_at(&file.source_bytes, anchor_offset) != anchor
    {
        return Err(CoreError::InvalidInput("插入锚点不属于当前文件快照"));
    }
    let entry = find_entry_mut(&mut file.entries, &entry_id)
        .ok_or(CoreError::InvalidInput("插入目标条目不存在"))?;
    if !entry
        .elements
        .iter()
        .any(|element| element.source_range.start == anchor || element.source_range.end == anchor)
    {
        return Err(CoreError::InvalidInput("插入锚点必须位于条目元素边界"));
    }

    file.source_bytes
        .splice(anchor_offset..anchor_offset, content.iter().copied());
    rebase_ranges(
        &mut file.entries,
        EditRange::Insert {
            offset: anchor_offset,
            length: content.len(),
        },
        &file.source_bytes,
    )?;

    let entry = find_entry_mut(&mut file.entries, &entry_id)
        .ok_or(CoreError::InvalidState("插入后目标条目丢失"))?;
    let end_offset = anchor_offset + content.len();
    let element = OrgElement {
        kind,
        source_range: SourceRange::new(
            position_at(&file.source_bytes, anchor_offset),
            position_at(&file.source_bytes, end_offset),
        )?,
    };
    let index = entry
        .elements
        .iter()
        .position(|existing| existing.source_range.start.byte_offset >= anchor.byte_offset)
        .unwrap_or(entry.elements.len());
    entry.elements.insert(index, element);
    Ok(())
}

#[derive(Clone, Copy)]
enum EditRange {
    Replace { old: SourceRange, new_end: usize },
    Insert { offset: usize, length: usize },
}

fn rebase_ranges(
    entries: &mut [OrgEntry],
    edit: EditRange,
    source_bytes: &[u8],
) -> Result<(), CoreError> {
    for entry in entries {
        rebase_entry(entry, edit, source_bytes)?;
    }
    Ok(())
}

fn rebase_entry(
    entry: &mut OrgEntry,
    edit: EditRange,
    source_bytes: &[u8],
) -> Result<(), CoreError> {
    for element in &mut entry.elements {
        rebase_element(element, edit, source_bytes)?;
    }
    for child in &mut entry.children {
        rebase_entry(child, edit, source_bytes)?;
    }
    Ok(())
}

fn rebase_element(
    element: &mut OrgElement,
    edit: EditRange,
    source_bytes: &[u8],
) -> Result<(), CoreError> {
    let old = element.source_range;
    let (start, end) = match edit {
        EditRange::Replace {
            old: target,
            new_end,
        } => {
            let target_start = offset(target.start)?;
            let target_end = offset(target.end)?;
            let old_start = offset(old.start)?;
            let old_end = offset(old.end)?;
            let delta = (new_end - target_start) as isize - (target_end - target_start) as isize;
            if old == target {
                (target_start, new_end)
            } else if old_end <= target_start {
                (old_start, old_end)
            } else if old_start >= target_end {
                (shift(old_start, delta)?, shift(old_end, delta)?)
            } else if old_start <= target_start && old_end >= target_end {
                (old_start, shift(old_end, delta)?)
            } else {
                return Err(CoreError::InvalidState("元素来源范围与编辑范围非法交叉"));
            }
        }
        EditRange::Insert {
            offset: insertion_offset,
            length,
        } => {
            let old_start = offset(old.start)?;
            let old_end = offset(old.end)?;
            if old_start >= insertion_offset {
                (old_start + length, old_end + length)
            } else if old_end > insertion_offset {
                (old_start, old_end + length)
            } else {
                (old_start, old_end)
            }
        }
    };
    element.source_range = SourceRange::new(
        position_at(source_bytes, start),
        position_at(source_bytes, end),
    )?;
    if let OrgElementKind::Drawer(drawer) = &mut element.kind {
        for child in &mut drawer.elements {
            rebase_element(child, edit, source_bytes)?;
        }
    }
    Ok(())
}

fn find_entry_mut<'a>(entries: &'a mut [OrgEntry], id: &str) -> Option<&'a mut OrgEntry> {
    for entry in entries {
        if entry.id == id {
            return Some(entry);
        }
        if let Some(found) = find_entry_mut(&mut entry.children, id) {
            return Some(found);
        }
    }
    None
}

fn find_element_mut<'a>(
    entries: &'a mut [OrgEntry],
    target: &OrgElementLocator,
) -> Option<&'a mut OrgElement> {
    let entry = find_entry_mut(entries, &target.entry_id)?;
    find_element_in_slice(&mut entry.elements, target.source_range)
}

fn find_element_in_slice(
    elements: &mut [OrgElement],
    range: SourceRange,
) -> Option<&mut OrgElement> {
    for element in elements {
        if element.source_range == range {
            return Some(element);
        }
        if let OrgElementKind::Drawer(drawer) = &mut element.kind {
            if let Some(found) = find_element_in_slice(&mut drawer.elements, range) {
                return Some(found);
            }
        }
    }
    None
}

fn validate_content(content: &[u8]) -> Result<(), CoreError> {
    if content.is_empty() {
        return Err(CoreError::InvalidInput("元素编辑内容不能为空"));
    }
    std::str::from_utf8(content)
        .map_err(|_| CoreError::InvalidInput("元素编辑内容必须是 UTF-8 编码"))?;
    Ok(())
}

fn offset(position: SourcePosition) -> Result<usize, CoreError> {
    usize::try_from(position.byte_offset)
        .map_err(|_| CoreError::InvalidInput("源位置字节偏移超出文件范围"))
}

fn shift(value: usize, delta: isize) -> Result<usize, CoreError> {
    value
        .checked_add_signed(delta)
        .ok_or(CoreError::InvalidState("编辑后的源位置超出文件范围"))
}

fn position_at(source: &[u8], byte_offset: usize) -> SourcePosition {
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
    use crate::{OrgFile, OrgText};

    fn position(offset: u64) -> SourcePosition {
        SourcePosition::new(1, offset as u32, offset).unwrap()
    }

    fn element(start: u64, end: u64, text: &str) -> OrgElement {
        OrgElement {
            kind: OrgElementKind::Text(OrgText { text: text.into() }),
            source_range: SourceRange::new(position(start), position(end)).unwrap(),
        }
    }

    #[test]
    fn replacement_preserves_unmodified_bytes_and_rebases_later_elements() {
        let first = element(0, 1, "a");
        let second = element(1, 2, "b");
        let mut file = OrgFile::new(
            "repo".into(),
            "inbox.org".into(),
            b"ab".to_vec(),
            vec![OrgEntry {
                id: "entry".into(),
                parent_id: None,
                level: 1,
                elements: vec![first.clone(), second],
                children: vec![],
            }],
        )
        .unwrap();

        apply_edit(
            &mut file,
            OrgFileEdit::ReplaceElement {
                target: OrgElementLocator::for_element(&"entry".into(), &first),
                kind: OrgElementKind::Text(OrgText {
                    text: "alpha".into(),
                }),
                content: b"alpha".to_vec(),
            },
        )
        .unwrap();

        assert_eq!(serialize_file(&file), b"alphab");
        assert_eq!(
            file.entries[0].elements[1].source_range.start.byte_offset,
            5
        );
    }
}
