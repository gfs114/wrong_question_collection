import { router } from '@kit.ArkUI'
import { BODY_FONT_SIZE, PAGE_PADDING, themePalette } from '../constants/AppTheme'
import { SHEET_RADIUS } from '../constants/EditorialStyle'
import { UiStyle } from '../constants/UiStyle'
import { AiPlatform, AiPlatformAccess, AiPlatformCatalog } from '../models/ai/AiPlatformCatalog'
import {
  AiImportError, AiImportErrorCode, AiImportErrorMessages,
  AiProviderConfig, AiProviderConfigValidator, AiProviderId
} from '../models/ai/AiProviderConfig'
import { AiConnectionTestService } from '../services/ai/AiConnectionTestService'
import { AiCredentialStore } from '../services/ai/AiCredentialStore'
import { AiModelCatalogService } from '../services/ai/AiModelCatalogService'
import { AiProviderConfigStore } from '../services/ai/AiProviderConfigStore'
import { AppColors } from '../theme/AppColors'
import { AiPlatformSelectionState } from '../utils/AiPlatformSelectionState'
import { SafeAreaInsets, SafeAreaUtils } from '../utils/SafeAreaUtils'

@Entry
@Component
struct AiRecognitionSettingsPage {
  @StorageProp('darkMode') darkMode: boolean = false
  @StorageProp('safeAreaInsets') safeAreaInsets: SafeAreaInsets = { top: 0, left: 0, right: 0, bottom: 0 }
  @State providerId: string = AiProviderId.OPENAI
  @State model: string = ''
  @State baseUrl: string = 'https://api.openai.com/v1'
  @State platformLabel: string = '自定义'
  // 最近一次已应用的目录平台 id（供「重选同平台 = no-op」守卫读取；比较目录 id 而非持久化字符串）。
  @State appliedPlatformId: string = ''
  @State platformNote: string = ''
  @State availableModels: Array<string> = new Array<string>()
  @State urlEditable: boolean = false
  @State apiKey: string = ''
  @State showKey: boolean = false
  @State configured: boolean = false
  @State replacingCredential: boolean = false
  @State credentialUpdatePending: boolean = false
  @State pending: boolean = false
  @State statusMessage: string = ''
  @State failed: boolean = false
  private savedConfig: AiProviderConfig | null = null

  private colors(): AppColors {
    return themePalette(this.darkMode)
  }

  aboutToAppear(): void {
    this.loadSettings()
  }

  // 选择页只写回平台 id：必须先 peek 判空/判忙，通过后才 take，反序会把用户的选择静默吞掉。
  onPageShow(): void {
    const selectedId: string = AiPlatformSelectionState.shared().peek()
    if (selectedId.length === 0 || this.pending) return
    AiPlatformSelectionState.shared().take()
    this.applyPlatform(selectedId)
  }

  aboutToDisappear(): void {
    this.apiKey = ''
    this.showKey = false
  }

  onBackPress(): boolean {
    if (this.pending) return true
    this.leavePage()
    return true
  }

  private leavePage(): void {
    if (this.pending) return
    this.apiKey = ''
    this.showKey = false
    router.back()
  }

  private formConfig(): AiProviderConfig {
    return AiProviderConfigValidator.normalize(new AiProviderConfig(this.providerId, this.model, this.baseUrl))
  }

  private applyConfig(config: AiProviderConfig): void {
    this.providerId = config.providerId
    this.model = config.model
    this.baseUrl = config.baseUrl
    this.syncPlatformFromConfig()
  }

  // 应用选择页回传的目录 id：只采用平台地址；模型必须在用户填写 Key 后从平台实时获取。
  private applyPlatform(id: string): void {
    const platform: AiPlatform | null = AiPlatformCatalog.find(id)
    if (platform === null) return
    // 重选「当前已应用」的平台是 no-op：避免把用户尚未保存的 Model / 手填地址静默清空。
    // 用目录 id 比较（目录 id 恒小写），不比较持久化字符串，避免大小写变体让守卫失效。
    if (this.appliedPlatformId === platform.id) return
    this.appliedPlatformId = platform.id
    this.platformLabel = platform.nameZh
    this.platformNote = platform.note
    this.availableModels = new Array<string>()
    this.model = ''
    this.replacingCredential = true
    if (platform.access === AiPlatformAccess.GATEWAY) {
      this.providerId = AiProviderId.CUSTOM
      this.baseUrl = ''
      this.urlEditable = true
      this.statusMessage = platform.note.length > 0 ? platform.note : '该平台需自建兼容网关，请填写你自己的地址'
      this.failed = this.statusMessage.length > 0
    } else {
      this.providerId = platform.id
      this.baseUrl = platform.baseUrl
      this.urlEditable = platform.access === AiPlatformAccess.LOCAL_HTTP
      // 非 gateway 平台的风险/限制说明统一显示在地址下方（platformNote），不占用底部状态区。
      this.statusMessage = ''
      this.failed = false
    }
  }

  // 明文风险按「实际地址」判定，而不是按所选平台的目录 access：
  // 用户完全可能在 DIRECT 平台上手动填入 http://192.168.x 地址（校验器白名单放行），
  // 反之 LOCAL_HTTP 平台的 note 只是信息性文字，不应被涂成错误色。
  private isCleartextAddress(): boolean {
    return this.baseUrl.trim().toLowerCase().startsWith('http://')
  }

  // 展示层只认目录：未知/已移除的持久化 id 一律兜底「自定义」，绝不把 store 里的原始字符串渲染到 UI。
  private syncPlatformFromConfig(): void {
    const platform: AiPlatform | null = AiPlatformCatalog.find(this.providerId)
    if (platform === null) {
      this.appliedPlatformId = ''
      this.platformLabel = '自定义'
      this.platformNote = ''
      this.availableModels = new Array<string>()
      this.urlEditable = true
      return
    }
    this.appliedPlatformId = platform.id
    this.platformLabel = platform.nameZh
    this.platformNote = platform.note
    this.availableModels = new Array<string>()
    this.urlEditable = platform.access !== AiPlatformAccess.DIRECT
  }

  private showError(error: Error): void {
    this.failed = true
    const code: AiImportErrorCode = error instanceof AiImportError ? error.code : AiImportErrorCode.PROVIDER_UNAVAILABLE
    this.statusMessage = AiImportErrorMessages.forCode(code)
  }

  private modelOptions(): Array<SelectOption> {
    const options: Array<SelectOption> = new Array<SelectOption>()
    for (let index: number = 0; index < this.availableModels.length; index++) {
      options.push({ value: this.availableModels[index] })
    }
    return options
  }

  private selectedModelIndex(): number {
    for (let index: number = 0; index < this.availableModels.length; index++) {
      if (this.availableModels[index] === this.model) return index
    }
    return -1
  }

  private canUseSavedCredential(): boolean {
    if (!this.configured || this.replacingCredential || this.credentialUpdatePending || this.savedConfig === null) {
      return false
    }
    const currentScope: AiProviderConfig =
      new AiProviderConfig(this.providerId, this.savedConfig.model, this.baseUrl)
    return AiProviderConfigStore.sameCredentialScope(this.savedConfig, currentScope)
  }

  private async fetchCloudModels(): Promise<void> {
    if (this.pending) return
    const useTypedCredential: boolean = this.apiKey.trim().length > 0
    if (!useTypedCredential && !this.canUseSavedCredential()) {
      this.failed = true
      this.statusMessage = this.configured ? '请先输入新的 API Key 后再获取模型' : '请输入 API Key 后再获取模型'
      return
    }
    this.pending = true
    this.failed = false
    this.statusMessage = '正在从云端获取模型…'
    try {
      const service: AiModelCatalogService = new AiModelCatalogService()
      const models: Array<string> = useTypedCredential ?
        await service.fetchWithApiKey(this.baseUrl, this.apiKey) :
        await service.fetchWithSavedCredential(getContext(this), this.baseUrl)
      this.availableModels = models.slice()
      if (models.length === 0) {
        this.failed = true
        this.statusMessage = '云端没有返回可选择的模型'
        return
      }
      if (this.model.length > 0 && this.selectedModelIndex() < 0) {
        this.failed = true
        this.statusMessage = '已获取 ' + models.length.toString() + ' 个模型；当前模型不在列表，请重新选择后保存'
        return
      }
      this.statusMessage = '已获取 ' + models.length.toString() + ' 个模型，请选择后保存'
    } catch (err) {
      this.availableModels = new Array<string>()
      this.showError(err)
    } finally {
      this.pending = false
    }
  }

  private async loadSettings(): Promise<void> {
    if (this.pending) return
    this.pending = true
    let shouldFetchModels: boolean = false
    try {
      this.credentialUpdatePending = await AiProviderConfigStore.isCredentialUpdatePending(getContext(this))
      const config: AiProviderConfig | null = await AiProviderConfigStore.load(getContext(this))
      if (config !== null) this.applyConfig(config)
      if (this.credentialUpdatePending) throw new AiImportError(AiImportErrorCode.CREDENTIAL_UPDATE_PENDING)
      this.configured = await AiCredentialStore.hasCredential(getContext(this))
      this.savedConfig = config
      this.replacingCredential = this.configured && config === null
      shouldFetchModels = this.configured && config !== null
    } catch (err) {
      this.showError(err)
    } finally {
      this.apiKey = ''
      this.showKey = false
      this.pending = false
    }
    if (shouldFetchModels) await this.fetchCloudModels()
  }

  private async saveSettings(): Promise<void> {
    if (this.pending) return
    this.pending = true
    this.statusMessage = ''
    this.failed = false
    try {
      await AiProviderConfigStore.runUpdateExclusive<void>(async (): Promise<void> => {
        const config: AiProviderConfig = this.formConfig()
        if (this.apiKey.trim().length > 0) {
          this.credentialUpdatePending = true
          await AiProviderConfigStore.beginCredentialUpdate(getContext(this))
          const persisted: AiProviderConfig = await AiProviderConfigStore.save(getContext(this), config)
          this.applyConfig(persisted)
          await AiCredentialStore.save(getContext(this), this.apiKey)
          await AiProviderConfigStore.completeCredentialUpdate(getContext(this))
          this.credentialUpdatePending = false
          this.savedConfig = persisted
          this.replacingCredential = false
        } else {
          if (await AiProviderConfigStore.isCredentialUpdatePending(getContext(this))) {
            throw new AiImportError(AiImportErrorCode.CREDENTIAL_UPDATE_PENDING)
          }
          const saved: AiProviderConfig | null = await AiProviderConfigStore.load(getContext(this))
          if (await AiCredentialStore.hasCredential(getContext(this)) &&
            !AiProviderConfigStore.sameCredentialScope(saved, config)) {
            throw new AiImportError(AiImportErrorCode.REPLACEMENT_KEY_REQUIRED)
          }
          const persisted: AiProviderConfig = await AiProviderConfigStore.save(getContext(this), config)
          this.applyConfig(persisted)
          this.savedConfig = persisted
          this.replacingCredential = false
        }
        this.configured = await AiCredentialStore.hasCredential(getContext(this))
        this.statusMessage = '设置已保存'
      })
    } catch (err) {
      this.showError(this.credentialUpdatePending ? new AiImportError(AiImportErrorCode.CREDENTIAL_UPDATE_PENDING) : err)
    } finally {
      this.apiKey = ''
      this.showKey = false
      this.pending = false
    }
  }

  private async clearApiKey(): Promise<void> {
    if (this.pending) return
    this.pending = true
    this.failed = false
    try {
      await AiProviderConfigStore.runUpdateExclusive<void>(async (): Promise<void> => {
        this.credentialUpdatePending = true
        await AiProviderConfigStore.beginCredentialUpdate(getContext(this))
        await AiCredentialStore.clear(getContext(this))
        this.configured = false
        this.replacingCredential = false
        this.savedConfig = null
        this.availableModels = new Array<string>()
        await AiProviderConfigStore.completeCredentialUpdate(getContext(this))
        this.credentialUpdatePending = false
        this.statusMessage = 'API Key 已清除'
      })
    } catch (err) {
      this.showError(this.credentialUpdatePending ? new AiImportError(AiImportErrorCode.CREDENTIAL_UPDATE_PENDING) : err)
    } finally {
      this.apiKey = ''
      this.showKey = false
      this.pending = false
    }
  }

  private async testConnection(): Promise<void> {
    if (this.pending) return
    this.pending = true
    this.statusMessage = '正在测试连接…'
    this.failed = false
    try {
      const config: AiProviderConfig = this.formConfig()
      const service: AiConnectionTestService = new AiConnectionTestService()
      if (this.apiKey.trim().length > 0) {
        await service.testWithApiKey(config, this.apiKey)
        this.statusMessage = '连接成功，请保存设置'
        return
      }
      await AiProviderConfigStore.requireUsable(getContext(this), config)
      this.configured = await AiCredentialStore.hasCredential(getContext(this))
      if (!this.configured) throw new AiImportError(AiImportErrorCode.MISSING_API_KEY)
      await service.test(getContext(this), config)
      this.statusMessage = '连接成功'
    } catch (err) {
      this.showError(err)
    } finally {
      this.pending = false
    }
  }

  private openPlatformPicker(): void {
    if (this.pending) return
    this.getUIContext().getRouter().pushUrl({ url: 'pages/AiPlatformPickerPage' }).catch(() => {
      this.failed = true
      this.statusMessage = '平台选择页面暂不可用，请稍后重试'
    })
  }

  @Builder
  private FieldLabel(label: string) {
    Text(label)
      .fontSize(UiStyle.DETAIL_SIZE)
      .fontColor(this.colors().textPrimary)
      .fontWeight(FontWeight.Medium)
  }

  @Builder
  private HeaderBar() {
    Row({ space: 12 }) {
      Button('返回')
        .type(ButtonType.Normal)
        .constraintSize({ minWidth: UiStyle.TOUCH_TARGET, minHeight: UiStyle.TOUCH_TARGET })
        .fontSize(UiStyle.DETAIL_SIZE)
        .fontColor(UiStyle.action(this.darkMode))
        .backgroundColor(this.colors().pageBackground)
        .enabled(!this.pending)
        .accessibilityText('返回')
        .onClick(() => this.leavePage())

      Text('AI 识别设置')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().textPrimary)
    }
    .width('100%')
    .constraintSize({ maxWidth: UiStyle.CONTENT_WIDTH, minHeight: UiStyle.TOUCH_TARGET })
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
  }

  @Builder
  private StatusNotice() {
    if (this.statusMessage.length > 0) {
      Text(this.statusMessage)
        .width('100%')
        .constraintSize({ maxWidth: UiStyle.CONTENT_WIDTH, minHeight: UiStyle.TOUCH_TARGET })
        .padding({ left: 16, right: 16, top: 13, bottom: 13 })
        .fontSize(BODY_FONT_SIZE)
        .fontColor(this.failed ? UiStyle.errorText(this.darkMode) : this.colors().successText)
        .backgroundColor(this.failed ? this.colors().errorSoft : this.colors().brandSoft)
        .borderRadius(UiStyle.CONTROL_RADIUS)
        .accessibilityText((this.failed ? '操作失败：' : '操作状态：') + this.statusMessage)
    }
  }

  @Builder
  private ServiceAndModelSection() {
    Column({ space: UiStyle.FIELD_GAP }) {
      Text('服务与模型')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().textPrimary)

      Column({ space: 8 }) {
        this.FieldLabel('识别平台')
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text(this.platformLabel)
              .fontSize(UiStyle.BODY_SIZE)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors().textPrimary)
              .maxLines(2)
            Text('选择平台后填写 API Key，将自动获取云端模型')
              .fontSize(12)
              .fontColor(this.colors().textCaption)
              .maxLines(2)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Button('切换平台')
            .type(ButtonType.Normal)
            .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
            .fontSize(UiStyle.DETAIL_SIZE)
            .fontColor(UiStyle.action(this.darkMode))
            .backgroundColor(this.colors().brandSoft)
            .borderRadius(UiStyle.CONTROL_RADIUS)
            .enabled(!this.pending)
            .onClick(() => {
              this.openPlatformPicker()
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 8 }) {
        this.FieldLabel('API 地址')
        TextInput({ text: this.baseUrl, placeholder: this.urlEditable ? 'https://服务地址/v1' : '' })
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontSize(UiStyle.BODY_SIZE)
          .fontColor(this.colors().textPrimary)
          .backgroundColor(this.colors().inputBackground)
          .border({ width: 1, color: this.colors().divider })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(!this.pending && this.urlEditable)
          .onChange((value: string) => {
            this.baseUrl = value
            this.model = ''
            this.availableModels = new Array<string>()
            this.replacingCredential = true
          })

        if (this.isCleartextAddress()) {
          Text('⚠ 明文 HTTP 仅适用于本机或私网服务，API Key 会以明文在局域网内传输。')
            .width('100%')
            .fontSize(UiStyle.DETAIL_SIZE)
            .fontColor(UiStyle.errorText(this.darkMode))
            .lineHeight(22)
        }

        Button(this.urlEditable ? '完成自定义地址' : '自定义地址')
          .type(ButtonType.Normal)
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontSize(UiStyle.DETAIL_SIZE)
          .fontColor(UiStyle.action(this.darkMode))
          .backgroundColor(this.colors().cardBackground)
          .enabled(!this.pending)
          .onClick(() => {
            this.urlEditable = !this.urlEditable
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: 1, color: this.colors().divider })
    .borderRadius(SHEET_RADIUS)
  }

  @Builder
  private CredentialSection() {
    Column({ space: UiStyle.FIELD_GAP }) {
      Row() {
        Text('密钥管理')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().textPrimary)
        Blank()
        Text(this.credentialUpdatePending ? '更新未完成' :
          (this.configured ? (this.replacingCredential ? '待更换' : '已配置') : '未配置'))
          .fontSize(UiStyle.DETAIL_SIZE)
          .fontColor(this.credentialUpdatePending || this.replacingCredential ?
            UiStyle.errorText(this.darkMode) :
            (this.configured ? this.colors().successText : this.colors().textCaption))
      }
      .width('100%')

      Column({ space: 8 }) {
        this.FieldLabel('API Key')
        if (this.configured && !this.replacingCredential && !this.credentialUpdatePending) {
          Text('••••••••（已安全保存）')
            .width('100%')
            .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
            .padding({ left: 16, right: 16, top: 13, bottom: 13 })
            .fontSize(UiStyle.BODY_SIZE)
            .fontColor(this.colors().textPrimary)
            .backgroundColor(this.colors().inputBackground)
            .border({ width: 1, color: this.colors().divider })
            .borderRadius(UiStyle.CONTROL_RADIUS)
            .accessibilityText('API Key 已安全保存')

          Button('更换 API Key')
            .type(ButtonType.Normal)
            .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
            .fontSize(UiStyle.DETAIL_SIZE)
            .fontColor(UiStyle.action(this.darkMode))
            .backgroundColor(this.colors().cardBackground)
            .enabled(!this.pending)
            .onClick(() => {
              this.replacingCredential = true
              this.availableModels = new Array<string>()
            })
        } else {
          TextInput({ text: this.apiKey, placeholder: '输入新的 API Key' })
            .width('100%')
            .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
            .type(this.showKey ? InputType.Normal : InputType.Password).showPasswordIcon(false)
            .fontSize(UiStyle.BODY_SIZE)
            .fontColor(this.colors().textPrimary)
            .backgroundColor(this.colors().inputBackground)
            .border({ width: 1, color: this.colors().divider })
            .borderRadius(UiStyle.CONTROL_RADIUS)
            .enabled(!this.pending)
            .onChange((value: string) => {
              this.apiKey = value
              this.replacingCredential = true
              this.model = ''
              this.availableModels = new Array<string>()
            })
            .onSubmit(() => { this.fetchCloudModels() })
            .onBlur(() => {
              if (this.apiKey.trim().length > 0 && this.availableModels.length === 0) {
                this.fetchCloudModels()
              }
            })

          Button(this.showKey ? '隐藏本次输入' : '显示本次输入')
            .type(ButtonType.Normal)
            .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
            .fontSize(UiStyle.DETAIL_SIZE)
            .fontColor(this.apiKey.length > 0 ? UiStyle.action(this.darkMode) : this.colors().disabled)
            .backgroundColor(this.colors().cardBackground)
            .enabled(!this.pending && this.apiKey.length > 0)
            .onClick(() => { this.showKey = !this.showKey })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 8 }) {
        this.FieldLabel('云端模型')
        if (this.model.length > 0) {
          Text('当前模型：' + this.model)
            .width('100%')
            .fontSize(UiStyle.DETAIL_SIZE)
            .fontColor(this.colors().textCaption)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.availableModels.length > 0) {
          Select(this.modelOptions())
            .selected(this.selectedModelIndex())
            .value(this.model.length > 0 ? this.model : '选择模型')
            .width('100%')
            .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
            .font({ size: UiStyle.BODY_SIZE })
            .fontColor(this.colors().textPrimary)
            .backgroundColor(this.colors().inputBackground)
            .borderRadius(UiStyle.CONTROL_RADIUS)
            .enabled(!this.pending)
            .onSelect((index: number, value: string) => {
              this.model = value
            })
        } else {
          Text(this.model.length > 0 ? '模型目录暂不可用，可重新获取' :
            (this.canUseSavedCredential() ? '正在加载已保存配置的模型目录' : '输入完整 API Key 后将自动获取可用模型'))
            .width('100%')
            .fontSize(UiStyle.DETAIL_SIZE)
            .fontColor(this.colors().textCaption)
            .lineHeight(22)
        }

        Button(this.pending ? '正在获取…' :
          (this.availableModels.length > 0 ? '重新获取模型' : '获取模型'))
          .type(ButtonType.Normal)
          .width('100%')
          .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
          .fontSize(UiStyle.DETAIL_SIZE)
          .fontColor(UiStyle.action(this.darkMode))
          .backgroundColor(this.colors().cardBackground)
          .border({ width: 1, color: UiStyle.action(this.darkMode) })
          .borderRadius(UiStyle.CONTROL_RADIUS)
          .enabled(!this.pending && (this.apiKey.trim().length > 0 || this.canUseSavedCredential()))
          .onClick(() => { this.fetchCloudModels() })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Button('保存设置')
        .type(ButtonType.Normal)
        .width('100%')
        .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
        .fontSize(UiStyle.BODY_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiStyle.onAction(this.darkMode))
        .backgroundColor(UiStyle.action(this.darkMode))
        .borderRadius(UiStyle.CONTROL_RADIUS)
        .enabled(!this.pending && this.model.trim().length > 0)
        .onClick(() => { this.saveSettings() })

      Divider().color(this.colors().divider)

      Button('清除 API Key')
        .type(ButtonType.Normal)
        .width('100%')
        .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
        .fontSize(UiStyle.DETAIL_SIZE)
        .fontColor(UiStyle.errorText(this.darkMode))
        .backgroundColor(this.colors().cardBackground)
        .enabled(!this.pending)
        .onClick(() => { this.clearApiKey() })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: 1, color: this.colors().divider })
    .borderRadius(SHEET_RADIUS)
  }

  @Builder
  private ConnectionSection() {
    Column({ space: 12 }) {
      Text('连接验证')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colors().textPrimary)

      Text('测试连接会发送一张极小测试图片，可能产生极少量模型费用')
        .width('100%')
        .fontSize(UiStyle.DETAIL_SIZE)
        .fontColor(this.colors().textCaption)
        .lineHeight(22)

      Button(this.pending ? '正在处理…' : '测试连接')
        .type(ButtonType.Normal)
        .width('100%')
        .constraintSize({ minHeight: UiStyle.TOUCH_TARGET })
        .fontSize(UiStyle.BODY_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiStyle.action(this.darkMode))
        .backgroundColor(this.colors().cardBackground)
        .border({ width: 1, color: UiStyle.action(this.darkMode) })
        .borderRadius(UiStyle.CONTROL_RADIUS)
        .enabled(!this.pending)
        .onClick(() => { this.testConnection() })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: 1, color: this.colors().divider })
    .borderRadius(SHEET_RADIUS)
  }

  build() {
    Column() {
      this.HeaderBar()
      this.StatusNotice()
      Scroll() {
        Column({ space: UiStyle.GROUP_GAP }) {
          Column({ space: 6 }) {
            Text('AI 视觉识别（推荐）')
              .width('100%')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.colors().textPrimary)
            Text('配置图片识别服务，保存后可在 PDF 导入中使用')
              .width('100%')
              .fontSize(UiStyle.DETAIL_SIZE)
              .fontColor(this.colors().textCaption)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          this.ServiceAndModelSection()
          this.CredentialSection()
          this.ConnectionSection()
        }
        .width('100%')
        .padding({ top: 16, bottom: PAGE_PADDING })
      }
      .layoutWeight(1)
      .width('100%')
      .constraintSize({ maxWidth: UiStyle.CONTENT_WIDTH })
      .scrollBar(BarState.Off)
      .padding({ left: PAGE_PADDING, right: PAGE_PADDING })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
    .padding({
      top: SafeAreaUtils.top(this.safeAreaInsets),
      bottom: SafeAreaUtils.bottom(this.safeAreaInsets),
      left: SafeAreaUtils.left(this.safeAreaInsets),
      right: SafeAreaUtils.right(this.safeAreaInsets)
    })
  }
}
