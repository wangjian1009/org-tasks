import { UiColor } from './Theme'

// 输入是 Core 生成的安全 HTML 片段，宿主只负责阅读版式和主题。
export function orgDocumentPage(fragment: string, empty: boolean, embedded: boolean = false,
  backgroundColor: string = UiColor.surface, embeddedPadding: number = 16,
  fileReading: boolean = false, fileContext: string = '', flowReading: boolean = false,
  compactLogs: boolean = false, projectReading: boolean = false): string {
  const reading = fileReading && (!embedded || flowReading)
  const context = fileContext.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'">
<style>
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; padding: 18px 20px 40px; background: ${backgroundColor}; color: ${UiColor.text}; font: 16px/1.65 sans-serif; overflow-wrap: anywhere; }
main, section { min-width: 0; }
p { margin: 8px 0 14px; white-space: pre-wrap; }
.embedded { padding: 4px ${embeddedPadding}px 20px; }
details.heading { margin: 18px 0 12px; }
details.heading > summary { position: relative; list-style: none; padding-right: 28px; cursor: pointer; line-height: 1.35; }
summary::-webkit-details-marker { display: none; }
details.heading > summary::after { content: ''; position: absolute; right: 3px; top: 8px; width: 8px; height: 8px; border-right: 2px solid ${UiColor.secondary}; border-bottom: 2px solid ${UiColor.secondary}; transform: rotate(-45deg); }
details.heading[open] > summary::after { transform: rotate(45deg); }
.heading-title { font-size: 22px; font-weight: 600; color: #BCA5ED; }
.level-1 > summary .heading-title { font-size: 26px; }
.level-2 > summary .heading-title { font-size: 23px; }
.level-4 > summary .heading-title, .level-5 > summary .heading-title, .level-6 > summary .heading-title { font-size: 20px; }
.todo { font-weight: 650; }
.pending { color: #81CB91; }
.done { color: ${UiColor.secondary}; }
.priority { color: #E5BC77; font-size: .8em; }
.tags { display: inline; }
.file-tags { margin: -6px 0 12px; }
.file-tags .tag:first-child { margin-left: 0; }
.tag { display: inline-block; margin: 4px 0 2px 7px; padding: 2px 9px; border-radius: 20px; background: #503548; color: #F2ABCC; font-size: 12px; vertical-align: middle; }
.title-count { display: inline-flex; align-items: center; gap: 5px; padding: 3px 7px; margin: 0 3px; border-radius: 7px; background: #393E3C; color: ${UiColor.secondary}; font: normal 12px/1.4 sans-serif; vertical-align: middle; white-space: nowrap; }
.title-count.active { color: ${UiColor.primary}; } .title-count.complete { color: ${UiColor.done}; }
.count-ring { display: inline-block; width: 14px; height: 14px; border-radius: 50%; background: conic-gradient(currentColor var(--count-turn), #686763 0); mask: radial-gradient(transparent 5px, black 5.5px); }
.planning { font-size: 13px; line-height: 1.65; margin-top: 7px; color: ${UiColor.secondary}; }
.timestamp { color: #87B9EF; text-decoration: underline; text-underline-offset: 3px; }
.link { color: ${UiColor.primary}; text-decoration: underline; text-underline-offset: 3px; }
a.link { cursor: pointer; }
.link.unsupported { color: ${UiColor.secondary}; text-decoration-style: dashed; cursor: default; }
.drawer { color: ${UiColor.secondary}; font-size: 13px; margin: 8px 0 12px; }
.drawer > summary { cursor: pointer; }
dl { margin: 8px 0; } dt { font-weight: 600; } dd { margin: 0 0 6px 16px; white-space: pre-wrap; }
.table-scroll { overflow-x: auto; margin: 10px 0 4px; }
table { border-collapse: collapse; font-size: 15px; white-space: nowrap; min-width: 60%; }
td { border: 1px solid ${UiColor.outline}; padding: 5px 10px; text-align: right; }
td:first-child { text-align: left; }
thead { font-weight: 600; background: ${UiColor.container}; }
.metadata { font: 12px/1.5 sans-serif; color: ${UiColor.secondary}; white-space: pre-wrap; margin: 6px 0; }
.source { background: #3B3742; border-radius: 9px; margin: 10px 0 16px; padding: 10px 12px; }
.source-language { font: 12px/1.5 monospace; color: ${UiColor.secondary}; margin-bottom: 5px; }
pre { overflow-x: auto; font: 14px/1.65 monospace; margin: 8px 0 14px; }
.source-code { margin: 0; color: #DED4F0; }
code { background: #3B3742; color: #DEC5F6; border-radius: 4px; padding: 1px 4px; font-family: monospace; }
pre code { padding: 0; background: transparent; }
blockquote { margin: 10px 0; padding: 2px 14px; border-left: 3px solid ${UiColor.primary}; color: ${UiColor.secondary}; }
ul, ol { padding-left: 24px; } li > p { margin: 2px 0; }
li.checkbox-item { display: block; max-width: 100%; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
li.checkbox-item .checkbox { display: inline-block; width: 1.4em; white-space: nowrap; font-family: monospace; color: ${UiColor.primary}; }
.verse { white-space: pre-wrap; } hr { border: 0; border-top: 1px solid ${UiColor.outline}; }
.empty { padding-top: 64px; text-align: center; color: ${UiColor.secondary}; }
/* 文件整篇阅读独立启用；任务编辑与冲突阅读沿用原有版式。 */
html { background: ${backgroundColor}; }
.file-reading { max-width: 740px; margin: 0 auto; padding: 18px 22px 60px; line-height: 1.78; }
.file-context { margin: 0 0 14px; font-size: 11px; line-height: 1.7; color: ${UiColor.secondary}; }
.file-reading p { margin: 0 0 17px; }
.file-reading details.heading { margin: 28px 0 0; scroll-margin-top: 18px; }
.file-reading details.heading > summary { padding: 0; margin-bottom: 12px; min-height: 34px; line-height: 1.45; }
.file-reading details.heading > summary::after { right: auto; left: -13px; top: 13px; width: 5px; height: 5px; border-width: 1.4px; }
.file-reading .heading-title { font-size: 18px; font-weight: 600; color: #E5E6DF; }
.file-reading .level-1 > summary .heading-title { font-size: 24px; }
.file-reading .level-2 > summary .heading-title { font-size: 20px; }
.file-reading .level-3 > summary .heading-title, .file-reading .level-4 > summary .heading-title,
.file-reading .level-5 > summary .heading-title, .file-reading .level-6 > summary .heading-title { font-size: 18px; }
.file-reading details.level-2, .file-reading details.level-3, .file-reading details.level-4,
.file-reading details.level-5, .file-reading details.level-6 { margin-top: 22px; }
.file-reading .todo { display: inline-block; font: 600 11px/1.6 sans-serif; padding: 1px 5px; border-radius: 4px; vertical-align: 3px; }
.file-reading .pending { background: #334237; color: #A6C6AE; }
.file-reading .done { background: ${UiColor.container}; color: ${UiColor.secondary}; }
.file-reading .priority { font-size: 12px; color: ${UiColor.secondary}; }
.file-reading .file-tags { margin: 0 0 18px; }
.file-reading .tag { margin: 3px 0 2px 6px; padding: 1px 7px; border-radius: 5px; background: #363936; color: #B5BBB5; font: 11px/1.8 sans-serif; }
.file-reading .file-tags .tag { background: #30423E; color: #8EC9BD; }
.file-reading .file-tags .tag:first-child { margin-left: 0; }
.file-reading .planning { margin: -3px 0 12px; font-size: 12px; line-height: 1.8; }
.file-reading .timestamp { color: ${UiColor.secondary}; text-decoration: none; }
.file-reading .link { color: ${UiColor.primary}; text-decoration-color: currentColor; text-underline-offset: 4px; }
.file-reading .link.unsupported { color: ${UiColor.secondary}; }
.file-reading .table-scroll { margin: 18px 0 23px; max-width: 100%; border: 1px solid ${UiColor.divider}; border-radius: 7px; }
.file-reading table { width: 100%; font-size: 14px; line-height: 1.65; }
.file-reading td { border: 0; border-bottom: 1px solid ${UiColor.divider}; padding: 10px 8px; font-variant-numeric: tabular-nums; }
.file-reading tbody tr:last-child td { border-bottom: 0; }
.file-reading thead { background: ${UiColor.container}; color: #C8CDC3; }
.file-reading .source { padding: 0; margin: 17px 0 23px; overflow: hidden; border: 1px solid ${UiColor.divider}; border-radius: 8px; background: #252623; }
.file-reading .source-language { margin: 0; padding: 9px 13px; border-bottom: 1px solid #3B3F36; font-size: 11px; }
.file-reading .source-code { padding: 13px; color: #C5CFC2; font-size: 13px; line-height: 1.8; }
.file-reading code { background: #383B36; color: #C5CFC2; }
.file-reading pre code { background: transparent; }
.file-reading blockquote { margin: 19px 0; padding: 2px 0 2px 13px; border-left: 2px solid #5D8B80; }
.file-reading blockquote p { margin: 0; }
.file-reading ul, .file-reading ol { padding-left: 22px; margin: 0 0 18px; }
.file-reading li { margin: 7px 0; }
.file-reading li > p { margin: 2px 0; }
.file-reading li.checkbox-item { position: relative; padding-left: 25px; margin-left: -22px; overflow: visible; white-space: normal; text-overflow: clip; }
.file-reading li.checkbox-item .checkbox { position: absolute; left: 0; top: 0; color: #91A89D; }
.file-reading .drawer { margin: 17px 0 20px; padding: 10px 0; border-top: 1px solid ${UiColor.divider}; border-bottom: 1px solid ${UiColor.divider}; font-size: 12px; }
.file-reading .drawer > summary { min-height: 24px; }
.conflict-card { margin: 18px 0 22px; padding: 16px; border: 1px solid #455B52; border-left: 3px solid #79B99A; border-radius: 14px; background: #2C3630; font-size: 14px; line-height: 1.65; }
.conflict-card-header { display: flex; gap: 9px; align-items: flex-start; margin-bottom: 12px; }
.conflict-card-badge { flex-shrink: 0; padding: 2px 8px; border-radius: 5px; background: #395044; color: #A5D9B6; font-size: 11px; line-height: 1.8; }
.conflict-card-title { min-width: 0; font-size: 17px; color: #E5E6DF; font-weight: 600; line-height: 1.6; }
.conflict-card-body { color: #CDD3CA; white-space: pre-wrap; overflow-wrap: anywhere; font-size: 14px; line-height: 1.75; }
.file-reading .conflict-card-body .drawer { margin: 8px 0 12px; padding: 0; border: 0; }
.conflict-card-body p:last-child { margin-bottom: 0; }
.conflict-card-body details { margin: 12px 0; }
.conflict-card-body summary { list-style: none; }
.conflict-card-actions { display: flex; gap: 10px; margin-top: 16px; }
.conflict-card-actions button { flex: 1; min-height: 42px; padding: 8px 14px; border: 0; border-radius: 9px; background: #73B8A8; color: #15342C; font: 600 13px/1.4 sans-serif; }
.conflict-card-actions button:last-child { background: #3B443D; color: #D3D8CF; }
.conflict-delete { border-color: #654650; border-left-color: #D98899; background: #3B2E33; }
.conflict-delete .conflict-card-badge { background: #593A44; color: #EDACBA; }
.conflict-delete .conflict-card-actions button:first-child { background: #D695A4; color: #44202A; }
.conflict-modify { border-color: #5B5541; border-left-color: #CAB57D; background: #37352C; }
.conflict-modify .conflict-card-badge { background: #504B38; color: #E4D2A1; }
body.compact-logs { padding: 0; color: ${UiColor.secondary}; font: 12px/1.5 sans-serif; }
.task-log { min-width: 0; }
.task-log-heading { display: flex; flex-wrap: wrap; align-items: baseline; gap: 0 10px; }
.task-log-time { color: ${UiColor.disabled}; font-size: 11px; }
.task-log-detail { color: ${UiColor.disabled}; font-size: 11px; }
.task-log-note { margin-top: 2px; font-size: 13px; }
.task-log.taskStateChange .task-log-note { padding-left: 8px; }
.task-log :is(p, ul, ol, pre, blockquote, .source, .drawer, .table-scroll) { margin-top: 2px; margin-bottom: 2px; }
.task-log :is(p, li, pre, code, table, .source-code, .heading-title) { font-size: 13px; line-height: 1.5; color: inherit; }
.task-log :is(ul, ol) { padding-left: 18px; }
.task-log :is(.timestamp, .link) { color: inherit; }
.task-log .timestamp { text-decoration: none; }
.task-log .source { padding: 4px 8px; background: transparent; }
.task-log blockquote { padding-left: 8px; border-left: 1px solid ${UiColor.outline}; }
.project-reading { line-height: 1.75; padding: 16px 24px 60px; }
.embedded.project-reading, .file-reading.project-reading.embedded-section { padding: 0; max-width: none; }
/* 将片段首尾留白计入 WebView 测量，章节舒展、清单连续排列。 */
.file-reading.project-reading.embedded-section { display: flow-root; }
/* 原生项目区块的段距由 Core 边界决定，单段 WebView 不再叠加 margin 或最小行高。 */
.embedded.project-reading.embedded-section { display: flow-root; font: 16px/26px sans-serif; }
.embedded.project-reading.embedded-section > p { margin: 0; }
.embedded.project-reading.embedded-section > :first-child { margin-top: 0; }
.embedded.project-reading.embedded-section > :last-child { margin-bottom: 0; }
.file-reading.project-reading p { margin: 0 0 20px; }
.file-reading.project-reading ul, .file-reading.project-reading ol { margin: 0 0 20px; }
.file-reading.project-reading li { margin: 4px 0; }
.file-reading.project-reading li > p { margin: 0; }
.file-reading.project-reading li > ul, .file-reading.project-reading li > ol { margin: 4px 0 0; }
.project-reading .document-header { margin-bottom: 24px; padding-bottom: 22px; border-bottom: 1px solid #454746; }
.project-reading .document-category { font-size: 12px; color: ${UiColor.secondary}; margin-bottom: 12px; }
.project-reading .document-project-name { font-size: 28px; font-weight: 650; line-height: 1.35; color: #F0EFED; margin-bottom: 12px; }
.project-reading .file-tags { margin: 0; }
.project-reading .file-tags .tag { margin: 0 10px 4px 0; padding: 0; border-radius: 0; background: transparent; color: ${UiColor.primary}; font-size: 12px; }
.project-reading .file-tags .tag::before { content: '#'; }
.project-reading .file-tags:empty { display: none; }
.project-reading .document-file-title { font-size: 13px; margin: 8px 0; }
.project-reading .document-file-title::before { content: '文档　'; color: #AEACA9; }
.project-reading .file-context { font-size: 12px; margin: 12px 0 0; user-select: text; }
.project-reading .document-file-stats { font-size: 11px; color: #AEACA9; margin-top: 14px; }
.project-reading .file-properties { display: grid; grid-template-columns: minmax(72px, 30%) minmax(0, 1fr); gap: 8px 12px; font-size: 13px; margin: 16px 0 0; }
.project-reading .file-properties:empty { display: none; }
.project-reading dt { color: #AEACA9; font-weight: 400; }
.project-reading dd { margin: 0; min-width: 0; }
.project-reading .heading { margin: 28px 0 0; scroll-margin-top: 18px; }
.project-reading .heading-content > .heading { margin-top: 14px; padding-left: var(--heading-indent, 12px); box-shadow: inset 1px 0 var(--heading-guide, ${UiColor.divider}); }
.project-reading .heading-summary { margin-bottom: 12px; }
.project-reading .heading-title { color: #F0EFED; font-size: 18px; line-height: 1.5; }
.project-reading .level-1 > .heading-summary .heading-title { font-size: 22px; }
.project-reading .level-2 > .heading-summary .heading-title { font-size: 20px; }
.project-reading .task-heading > .heading-summary .heading-title { font-size: 17px; color: #D8D8D8; }
.project-reading .task-heading > .heading-summary { margin-bottom: 0; }
.project-reading .task-heading > .heading-summary .planning { margin: 4px 0 0; }
.project-reading .task-heading .todo { vertical-align: 1px; }
.project-reading .task-description { margin: 0; }
.project-reading .description-summary { display: flex; align-items: center; gap: 7px; min-height: 48px; width: fit-content; min-width: 96px; padding: 8px 0; list-style: none; cursor: pointer; font-size: 12px; color: ${UiColor.secondary}; }
.project-reading .description-summary::before { content: ''; width: 6px; height: 6px; margin: 0 3px; border-right: 1.5px solid currentColor; border-bottom: 1.5px solid currentColor; transform: rotate(-45deg); }
.project-reading .task-description[open] > .description-summary::before { transform: rotate(45deg); }
.project-reading .description-collapse, .project-reading .task-description[open] > .description-summary .description-expand { display: none; }
.project-reading .task-description[open] > .description-summary .description-collapse { display: inline; }
.project-reading .description-summary:focus-visible { outline: 1px solid ${UiColor.primary}; outline-offset: 2px; border-radius: 3px; }
.project-reading .task-description > .heading-body { padding: 4px 0 8px; }
.project-reading .task-description + .heading { margin-top: 0; }
.project-reading [data-org-state="Doing"] > .heading-summary .todo { background: #32423F; color: #5AC4B9; }
.project-reading [data-org-state="Wait"] > .heading-summary .todo { background: #403D33; color: #E3C98B; }
.project-reading [data-org-state="Done"] > .heading-summary .todo { background: #333F36; color: #8FCCA1; }
.project-reading [data-org-state="Done"] > .heading-summary .heading-title,
.project-reading [data-org-state="Cancel"] > .heading-summary .heading-title { color: ${UiColor.secondary}; }
.project-reading .table-scroll { border: 0; border-radius: 0; }
.project-reading table { min-width: 100%; white-space: normal; }
.project-reading td { min-width: 6em; max-width: 22em; text-align: left; }
.project-reading .table-scroll::after { content: '表格较宽时可左右滑动'; display: block; color: #92938F; font-size: 11px; margin-top: 6px; }
.project-reading .drawer { border: 0; padding: 0; }
.project-reading .drawer-title { font-size: 12px; margin-bottom: 8px; color: #AEACA9; }
.project-reading .drawer dl { display: grid; grid-template-columns: minmax(72px,30%) minmax(0,1fr); gap: 8px 12px; }
.project-reading .metadata { white-space: pre-wrap; overflow-wrap: anywhere; }
@media (max-width: 340px) { .project-reading { padding-left: 16px; padding-right: 16px; } }

</style></head><body class="${reading ? 'file-reading' : embedded ? 'embedded' : ''}${compactLogs ? ' compact-logs' : ''}${projectReading ? ' project-reading' : ''}${projectReading && embedded ? ' embedded-section' : ''}">${reading && context ? `<div class="file-context">${context}</div>` : ''}${empty ? (projectReading ? fragment + '<p class="empty">项目还没有内容</p>' : '<p class="empty">空白 Org 文件</p>') : fragment}</body></html>`
}
