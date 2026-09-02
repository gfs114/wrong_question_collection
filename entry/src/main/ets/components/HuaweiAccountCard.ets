import { LoginWithHuaweiIDButton, loginComponentManager } from '@kit.AccountKit'
import { BusinessError } from '@kit.BasicServicesKit'
import {
  BODY_FONT_SIZE,
  CARD_RADIUS,
  themePalette
} from '../constants/AppTheme'
import { ImmersiveMaterials } from '../constants/ImmersiveMaterials'
import { AppColors } from '../theme/AppColors'

@Component
export struct HuaweiAccountCard {
  @Prop signedIn: boolean = false
  @Prop userId: string = ''
  @Prop deviceName: string = ''
  @Prop @Watch('onSigningInChanged') signingIn: boolean = false
  @Prop syncLabel: string = '本地模式'
  @Prop syncing: boolean = false
  @StorageProp('darkMode') darkMode: boolean = false
  onAuthorizationCode: (authorizationCode: string) => void = () => {
  }
  onLoginError: (code: number) => void = () => {
  }
  onSignOut: () => void = () => {
  }
  onSync: () => void = () => {
  }
  private registered: boolean = false
  private controller: loginComponentManager.LoginWithHuaweiIDButtonController =
    new loginComponentManager.LoginWithHuaweiIDButtonController()
  private params: loginComponentManager.LoginWithHuaweiIDButtonParams = {
    style: loginComponentManager.Style.BUTTON_RED,
    borderRadius: 24,
    supportDarkMode: true,
    loginType: loginComponentManager.LoginType.ID,
    textAndIconStyle: true
  }

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  aboutToAppear(): void {
    this.registerController()
    this.onSigningInChanged()
  }

  onSigningInChanged(): void {
    this.controller.setEnabled(!this.signingIn)
  }

  private registerController(): void {
    if (this.registered) {
      return
    }
    this.registered = true
    this.controller.onClickLoginWithHuaweiIDButton((err: BusinessError,
      credential: loginComponentManager.HuaweiIDCredential) => {
      if (err !== undefined && err !== null) {
        this.onLoginError(err.code)
        return
      }
      if (credential === undefined || credential.authorizationCode.length === 0) {
        this.onLoginError(0)
        return
      }
      this.onAuthorizationCode(credential.authorizationCode)
    })
  }

  build() {
    Column({ space: 14 }) {
      if (this.signedIn) {
        Row({ space: 12 }) {
          Text('账')
            .width(48)
            .height(48)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().brand)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.colors().pageBackground)
            .borderRadius(24)

          Column({ space: 4 }) {
            Text('已登录华为账号')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.colors().textPrimary)

            Text('当前设备：' + this.deviceName)
              .fontSize(13)
              .fontColor(this.colors().textCaption)

            Text('文字数据可同步，PDF 与题图仍只保存在本机')
              .fontSize(12)
              .fontColor(this.colors().textCaption)
              .maxLines(2)

            Text(this.syncLabel)
              .fontSize(12)
              .fontColor(this.colors().brand)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')

        Button(this.syncing ? '正在同步…' : '立即同步')
          .type(ButtonType.Normal)
          .width('100%')
          .height(46)
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.colors().onBrand)
          .backgroundColor(this.colors().brand)
          .borderRadius(16)
          .enabled(!this.signingIn && !this.syncing)
          .onClick(() => {
            this.onSync()
          })

        Button('退出登录')
          .type(ButtonType.Normal)
          .width('100%')
          .height(46)
          .fontSize(BODY_FONT_SIZE)
          .fontColor(this.colors().error)
          .backgroundColor(this.colors().pageBackground)
          .borderRadius(16)
          .enabled(!this.signingIn)
          .onClick(() => {
            this.onSignOut()
          })
      } else {
        Column({ space: 6 }) {
          Text('登录后开启云同步')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().textPrimary)

          Text('本地功能无需登录即可使用')
            .fontSize(BODY_FONT_SIZE)
            .fontColor(this.colors().textCaption)

          Text('登录后可在多台设备间同步题库与错题文字')
            .fontSize(12)
            .fontColor(this.colors().textCaption)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        LoginWithHuaweiIDButton({
          params: this.params,
          controller: this.controller
        })
        .width('100%')
        .height(48)

        if (this.signingIn) {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color(this.colors().brand)
            Text('正在建立安全会话')
              .fontSize(12)
              .fontColor(this.colors().textCaption)
          }
        }
      }
    }
    .width('100%')
    .padding(18)
    .borderRadius(CARD_RADIUS)
    .systemMaterial(ImmersiveMaterials.accountCardFor(this.darkMode))
  }
}
