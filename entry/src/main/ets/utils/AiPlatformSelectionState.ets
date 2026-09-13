export class AiPlatformSelectionState {
  private static instance: AiPlatformSelectionState | null = null
  private selectedId: string = ''

  private constructor() {
  }

  static shared(): AiPlatformSelectionState {
    if (AiPlatformSelectionState.instance === null) {
      AiPlatformSelectionState.instance = new AiPlatformSelectionState()
    }
    return AiPlatformSelectionState.instance
  }

  select(id: string): void {
    this.selectedId = id
  }

  peek(): string {
    return this.selectedId
  }

  take(): string {
    const value: string = this.selectedId
    this.selectedId = ''
    return value
  }
}
