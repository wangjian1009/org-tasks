import { RepoConfig } from './OrgTask'

export const SYSTEM_REPOSITORY_ID = 'org-tasks-system'
export const TRASH_FILE = 'trash.org'
export function isSystemRepository(repository: RepoConfig): boolean { return repository.id === SYSTEM_REPOSITORY_ID }
