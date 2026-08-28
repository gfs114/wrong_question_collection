export class DateUtils {
  private static pad(value: number, length: number): string {
    let result: string = value.toString()
    while (result.length < length) {
      result = '0' + result
    }
    return result
  }

  static formatDate(timestamp: number): string {
    const date: Date = new Date(timestamp)
    return DateUtils.pad(date.getFullYear(), 4) + '-' + DateUtils.pad(date.getMonth() + 1, 2) + '-' + DateUtils.pad(date.getDate(), 2)
  }

  static formatDateTime(timestamp: number): string {
    const date: Date = new Date(timestamp)
    return DateUtils.formatDate(timestamp) + ' ' + DateUtils.pad(date.getHours(), 2) + ':' + DateUtils.pad(date.getMinutes(), 2)
  }
}
