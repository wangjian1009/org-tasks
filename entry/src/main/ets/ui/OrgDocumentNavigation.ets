// 只访问 Core 生成的语义 HTML；目录序号在当前阅读快照内有效，不解析 Org 或写回文件。
export interface OrgDocumentChapter {
  index: number
  level: number
  title: string
}

export interface OrgDocumentOutline {
  chapters: OrgDocumentChapter[]
  activeIndex: number
}

export function documentOutlineScript(project: boolean = false): string {
  return `(function() {
    var activeIndex = -1;
    var chapters = Array.from(document.querySelectorAll('${project ? '.heading[data-org-start]' : 'details.heading'}')).map(function(node, index) {
      var summary = node.querySelector('${project ? ':scope > .heading-summary' : ':scope > summary'}');
      var heading = summary.querySelector('.heading-title');
      var title = heading.cloneNode(true);
      title.querySelectorAll('.todo, .priority, .title-count').forEach(function(part) { part.remove(); });
      var visible = true;
      for (var parent = node.parentElement; parent; parent = parent.parentElement) {
        if (parent.matches('details.heading:not([open])')) visible = false;
      }
      var top = summary.getBoundingClientRect().top;
      if (visible && top <= 48) activeIndex = index;
      return { index: index, level: Number(heading.getAttribute('aria-level')) || 1,
        title: title.textContent.trim() || '无标题' };
    });
    return JSON.stringify({ chapters: chapters, activeIndex: activeIndex });
  })()`
}

export function documentChapterScript(index: number, project: boolean = false): string {
  // 序号只由当前目录提供；仍拒绝无效值，避免进入脚本文本。
  if (!Number.isInteger(index) || index < 0) return 'false'
  return `(function() {
    var node = document.querySelectorAll('${project ? '.heading[data-org-start]' : 'details.heading'}')[${index}];
    if (!node) return false;
    ${project ? '' : `for (var parent = node; parent; parent = parent.parentElement) {
      if (parent.matches('details.heading')) parent.open = true;
    }`}
    node.scrollIntoView({ block: 'start', behavior: 'auto' });
    return true;
  })()`
}

export function documentExpandScript(expand: boolean, project: boolean = false): string {
  return `document.querySelectorAll('${project ? 'details.task-description' : 'details.heading'}').forEach(function(node) { node.open = ${expand ? 'true' : 'false'}; })`
}
