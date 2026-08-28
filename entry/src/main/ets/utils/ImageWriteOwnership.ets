export class ImageWriteOwnership {
  readonly temporaryPath: string
  readonly finalPath: string
  private temporaryOwned: boolean = false
  private finalOwned: boolean = false

  constructor(temporaryPath: string, finalPath: string) {
    if (temporaryPath.length === 0 || finalPath.length === 0 || temporaryPath === finalPath) {
      throw new Error('题图写入路径无效')
    }
    this.temporaryPath = temporaryPath
    this.finalPath = finalPath
  }

  markTemporaryCreated(): void {
    if (this.temporaryOwned || this.finalOwned) {
      throw new Error('题图临时文件所有权状态无效')
    }
    this.temporaryOwned = true
  }

  markMoved(): void {
    if (!this.temporaryOwned || this.finalOwned) {
      throw new Error('题图移动所有权状态无效')
    }
    this.temporaryOwned = false
    this.finalOwned = true
  }

  temporaryCleanupPath(): string {
    return this.temporaryOwned ? this.temporaryPath : ''
  }

  ownsFinalPath(): boolean {
    return this.finalOwned
  }

  resultPath(): string {
    if (!this.finalOwned) {
      throw new Error('题图最终路径尚未写入')
    }
    return this.finalPath
  }
}
