// 仅操作 Core 生成的语义 HTML，不读取或解析 Org 原文。
export function prepareProjectDocumentScript(): string {
  return `(() => {
    const header = document.querySelector('.document-header');
    if (!header || header.dataset.ready) return true;
    header.dataset.ready = 'true';
    const name = header.querySelector('.document-project-name');
    const category = header.querySelector('.document-category') || document.createElement('div');
    category.className = 'document-category';
    category.textContent = '项目' + (category.textContent ? ' / ' + category.textContent : '');
    header.prepend(category);
    if (name) { if (!name.textContent.trim()) name.textContent = '未命名项目'; name.setAttribute('role', 'heading'); name.setAttribute('aria-level', '1'); }
    const title = header.querySelector('.document-file-title');
    if (title && (!title.textContent.trim() || title.textContent === name?.textContent)) title.remove();
    const tags = header.querySelector('.file-tags');
    if (tags) header.insertBefore(tags, title?.isConnected ? title : header.querySelector('.file-properties'));
    document.querySelectorAll('.planning > span:first-child').forEach(label => {
      const names = { SCHEDULED: '计划', DEADLINE: '截止', CLOSED: '完成' };
      label.textContent = (names[label.textContent.trim().replace(':', '')] || label.textContent.trim()) + '：';
    });
    const context = document.querySelector('.file-context');
    if (context) header.insertBefore(context, title?.isConnected ? title : header.querySelector('.file-properties'));
    const stats = header.querySelector('.document-file-stats');
    if (stats) {
      const bytes = Number(stats.dataset.byteLength);
      const modified = stats.getAttribute('data-modified-at');
      const date = modified !== null ? new Date(Number(modified)) : null;
      stats.textContent = (date && !isNaN(date.getTime()) ? date.toLocaleString('zh-CN') + ' · ' : '') +
        (bytes < 1024 ? bytes + ' B' : (bytes / 1024).toFixed(1) + ' KB');
    }
    document.querySelectorAll('section.heading[data-org-task="true"]').forEach(node => {
      node.classList.add('task-heading');
      if (node.dataset.orgFoldable !== 'true') return;
      const body = node.querySelector(':scope > .heading-content > .heading-body');
      if (!body) return;
      const details = document.createElement('details');
      details.className = 'task-description';
      details.id = node.id + '-description';
      const summary = document.createElement('summary');
      summary.className = 'description-summary';
      const collapsed = document.createElement('span');
      collapsed.className = 'description-expand'; collapsed.textContent = '展开描述';
      const expanded = document.createElement('span');
      expanded.className = 'description-collapse'; expanded.textContent = '收起描述';
      summary.append(collapsed, expanded);
      details.appendChild(summary);
      body.replaceWith(details);
      details.appendChild(body);
    });
    document.querySelectorAll('.heading[data-org-start]').forEach(node => {
      let depth = 0;
      for (let parent = node.parentElement; parent; parent = parent.parentElement) {
        if (parent.matches('.heading')) depth++;
      }
      node.style.setProperty('--heading-indent', depth <= 2 ? '12px' : '0px');
      node.style.setProperty('--heading-guide', depth <= 2 ? '#494B48' : 'transparent');
    });
    const hasContent = document.querySelector('main .heading, main .heading-body > *');
    if (!hasContent) {
      const empty = document.createElement('p'); empty.className = 'empty'; empty.textContent = '项目还没有内容'; document.body.appendChild(empty);
    }
    return true;
  })()`
}

export function captureProjectReadingScript(): string {
  return `(() => {
    const nodes = Array.from(document.querySelectorAll('.heading[data-org-start]'));
    const visible = nodes.filter(n => n.getClientRects().length && n.getBoundingClientRect().top <= 48);
    const anchor = visible[visible.length - 1];
    return JSON.stringify({ open: Array.from(document.querySelectorAll('details.task-description[open]')).map(n => n.id),
      anchor: anchor?.id || '', offset: anchor?.getBoundingClientRect().top || 0, scroll: window.scrollY });
  })()`
}

export function restoreProjectReadingScript(state: string): string {
  return `(() => {
    try {
      const state = JSON.parse(${JSON.stringify(state)});
      document.querySelectorAll('details.task-description').forEach(n => { n.open = state.open.includes(n.id); });
      const anchor = document.getElementById(state.anchor);
      window.scrollTo(0, anchor ? window.scrollY + anchor.getBoundingClientRect().top - state.offset : state.scroll || 0);
    } catch (_) { /* 缺少有效会话状态时保留描述默认收起。 */ }
    return true;
  })()`
}
