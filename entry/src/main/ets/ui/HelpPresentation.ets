import { UiColor } from './Theme'

// 文档片段来自 Core，图片只使用随包读取的字节。
export function helpDocument(fragment: string, language: string): string {
  return `<!doctype html><html lang="${language}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
<style>
* {box-sizing:border-box}
body {margin:0 auto;max-width:720px;padding:24px 24px 48px;color:${UiColor.text};background:${UiColor.surface};
  font:16px/1.75 sans-serif;overflow-wrap:anywhere;}
h1,h2,h3,h4,h5,h6 {color:#f1efe8;line-height:1.4;scroll-margin-top:20px}
h1 {font-size:2em;line-height:1.34375;margin:0 0 16px}
h2 {font-size:1.375em;margin:32px 0 14px;padding-top:20px;border-top:1px solid ${UiColor.divider}}
h3 {font-size:1.125em;margin:24px 0 12px}
p {margin:0 0 16px}
.summary {color:${UiColor.secondary};margin-bottom:24px}
ul,ol {padding-inline-start:28px}
li {margin-block:8px}
li>p {margin:0}
li::marker,a {color:${UiColor.primary}}
a {text-underline-offset:3px}
dt {font-weight:600} dd {margin:0 0 12px 16px}
blockquote {margin:18px 0;padding:0 0 0 12px;border-left:2px solid ${UiColor.primary};color:${UiColor.secondary}}
blockquote p:last-child {margin-bottom:0}
.table-scroll,pre {max-width:100%;overflow-x:auto}
table {border-collapse:collapse;width:100%}
td {border:1px solid ${UiColor.divider};padding:8px 10px;min-width:5em}
thead {background:${UiColor.container};font-weight:600}
pre {background:${UiColor.container};border-radius:8px;padding:12px;white-space:pre;overflow-wrap:normal}
pre code {padding:0}
.example-copy {display:block;text-align:end;font-size:0.875em}
code {font-family:monospace;padding:1px 4px}
img {display:block;max-width:100%;height:auto;margin:16px auto}
.verse {white-space:pre-wrap}
</style></head><body>${fragment}</body></html>`
}
