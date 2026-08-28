export class IdUtils {
  private static counter: number = 0

  static create(prefix: string): string {
    IdUtils.counter += 1
    return prefix + Date.now().toString() + IdUtils.counter.toString()
  }
}
