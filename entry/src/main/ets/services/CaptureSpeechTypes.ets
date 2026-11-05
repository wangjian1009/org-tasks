import { common } from '@kit.AbilityKit'

export interface CaptureSpeechEvents {
  started: () => void
  result: (text: string) => void
  completed: () => void
  failed: (message: string) => void
}

export interface CaptureSpeechControl {
  start: (context: common.UIAbilityContext, events: CaptureSpeechEvents) => Promise<void>
  finish: (events: CaptureSpeechEvents) => Promise<boolean>
  cancel: (succeeded?: boolean) => Promise<void>
}
