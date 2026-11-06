import { UiColor } from './Theme'

// 输入是 Core 生成的安全 HTML 片段，宿主只负责阅读版式和主题。
export function orgDocumentPage(fragment: string, empty: boolean, embedded: boolean = false,
  backgroundColor: string = UiColor.surface, embeddedPadding: number = 16): string {
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
.timestamp, .link { color: #87B9EF; text-decoration: underline; text-underline-offset: 3px; }
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
</style></head><body class="${embedded ? 'embedded' : ''}">${empty ? '<p class="empty">空白 Org 文件</p>' : fragment}</body></html>`
}
