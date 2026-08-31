/**
 * ConnectivityPolicy decides when the UI may perform server-first mutations.
 *
 * The normal data flow is SERVER FIRST + OFFLINE READ ONLY:
 * - a mutation is allowed only when the user is signed in AND online;
 * - offline browsing is allowed only for a signed-in user who cannot reach
 *   the server (the account-scoped cloud cache stays visible, read-only);
 * - a signed-out user may never mutate and has no account-scoped cache.
 */
export class ConnectivityPolicy {
  static canMutate(isSignedIn: boolean, isOnline: boolean): boolean {
    return isSignedIn && isOnline
  }

  static isOfflineBrowsing(isSignedIn: boolean, isOnline: boolean): boolean {
    return isSignedIn && !isOnline
  }

  static isReadOnly(isSignedIn: boolean, isOnline: boolean): boolean {
    return !ConnectivityPolicy.canMutate(isSignedIn, isOnline)
  }

  static statusLabel(isSignedIn: boolean, isOnline: boolean): string {
    if (!isSignedIn) {
      return '未登录'
    }
    return isOnline ? '已连接' : '离线浏览'
  }

  static bannerMessage(isSignedIn: boolean, isOnline: boolean): string {
    if (!isSignedIn) {
      return '未登录：仅可浏览缓存数据，修改需先登录'
    }
    if (!isOnline) {
      return '离线浏览：当前仅可查看缓存，修改需联网'
    }
    return ''
  }

  static mutationBlockedMessage(isSignedIn: boolean, isOnline: boolean): string {
    if (!isSignedIn) {
      return '未登录，无法修改，请先登录华为账号'
    }
    if (!isOnline) {
      return '离线浏览：当前处于只读状态，无法修改'
    }
    return '当前无法修改，请稍后重试'
  }
}
