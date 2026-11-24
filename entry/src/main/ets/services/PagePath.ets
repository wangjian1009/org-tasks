import { CoreTask, CoreTaskPath } from './NativeCoreService'

export type RepositoryCreationMode = 'initialize' | 'remote' | 'localDirectory'

export interface PageParameters {
  readonly repoId?: string
  readonly coreRepoId?: string
  readonly path?: string
  readonly focusTask?: CoreTaskPath
  readonly focusLink?: string
  readonly syncId?: string
  readonly repositoryName?: string
  readonly backupTime?: number | null
  readonly backupPath?: string
  readonly section?: string
  readonly task?: CoreTask
  readonly memoId?: string
  readonly create?: boolean
  readonly repositoryCreation?: RepositoryCreationMode
  readonly configImportUri?: string
}

export interface PageRoute {
  readonly url: string
  readonly params?: PageParameters
}

// 有序页面路径：首项是一级入口，其余项是携带参数的深层页面。
export class PagePath {
  private readonly entries: PageRoute[]

  constructor(pages: PageRoute[]) {
    if (!pages.length || pages.some(page => !page.url.startsWith('pages/'))) throw new Error('页面路径无效')
    this.entries = pages.map((page: PageRoute): PageRoute => ({ url: page.url, params: page.params }))
  }

  get pages(): PageRoute[] { return this.entries.slice() }
  get current(): PageRoute { return this.entries[this.entries.length - 1] }
  get depth(): number { return this.entries.length }
  push(page: PageRoute): PagePath { return new PagePath(this.entries.concat([page])) }
  replace(page: PageRoute): PagePath { return new PagePath(this.entries.slice(0, -1).concat([page])) }
  parent(): PagePath { return new PagePath(this.depth > 1 ? this.entries.slice(0, -1) : this.entries) }
}
