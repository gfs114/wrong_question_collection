/**
 * AI 平台目录：纯静态数据（61 家），对外提供 all/find/search/byCategory/count 查询。
 * `access` 只表达「传输可达性」，不代表平台能力或质量，三类取值含义：
 *   DIRECT＝HTTPS + Bearer 直连 <baseUrl>/chat/completions，地址可直接使用；
 *   LOCAL_HTTP＝仅本机/私网 http（localhost、127.x、10.x、192.168.x、172.16-31.x）；
 *   GATEWAY＝本期不直连，baseUrl 为空串、原因写在 note，用户需改用「自定义」。
 * `docsUrl` 是官方文档出处，供用户核对与跳转；目录不含任何密钥/Token，自身不发起联网请求。
 */
export enum AiPlatformCategory {
  DIRECT = 'direct',
  INFERENCE = 'inference',
  AGGREGATOR = 'gateway',
  CLOUD = 'cloud',
  LOCAL = 'local'
}

export enum AiPlatformAccess {
  DIRECT = 'direct',
  LOCAL_HTTP = 'local_http',
  GATEWAY = 'gateway'
}

export class AiPlatformModel {
  readonly id: string
  readonly label: string
  readonly supportsVision: boolean

  constructor(id: string, label: string, supportsVision: boolean) {
    this.id = id
    this.label = label
    this.supportsVision = supportsVision
  }
}

export class AiPlatform {
  readonly id: string
  readonly nameZh: string
  readonly nameEn: string
  readonly category: AiPlatformCategory
  readonly access: AiPlatformAccess
  readonly baseUrl: string
  readonly models: Array<AiPlatformModel>
  readonly note: string
  readonly docsUrl: string

  constructor(id: string, nameZh: string, nameEn: string, category: AiPlatformCategory,
    access: AiPlatformAccess, baseUrl: string, models: Array<AiPlatformModel>,
    note: string, docsUrl: string) {
    this.id = id
    this.nameZh = nameZh
    this.nameEn = nameEn
    this.category = category
    this.access = access
    this.baseUrl = baseUrl
    this.models = models.slice()
    this.note = note
    this.docsUrl = docsUrl
  }
}

function vision(id: string, label: string): AiPlatformModel {
  return new AiPlatformModel(id, label, true)
}

const PLATFORMS: Array<AiPlatform> = [
  new AiPlatform('openai', 'OpenAI', 'OpenAI', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://api.openai.com/v1',
    [vision('gpt-6-astra', 'GPT-6 Astra'), vision('gpt-5.6-sol', 'GPT-5.6 Sol')],
    '唯一 supportsStructuredOutput = true', 'https://developers.openai.com/api/reference/overview'),
  new AiPlatform('anthropic', 'Anthropic Claude', 'Anthropic Claude', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://api.anthropic.com/v1',
    [vision('claude-opus-5', 'Claude Opus 5'), vision('claude-sonnet-5', 'Claude Sonnet 5'),
      vision('claude-haiku-4-5', 'Claude Haiku 4.5')],
    '官方 OpenAI 兼容层', 'https://docs.claude.com/en/api/openai-sdk'),
  new AiPlatform('gemini', 'Google Gemini', 'Google Gemini', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://generativelanguage.googleapis.com/v1beta/openai',
    [vision('gemini-3-flash', 'Gemini 3 Flash'), vision('gemini-3.1-pro-preview', 'Gemini 3.1 Pro Preview')],
    '官方 OpenAI 兼容层', 'https://ai.google.dev/gemini-api/docs/openai'),
  new AiPlatform('deepseek', '深度求索 DeepSeek', 'DeepSeek', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://api.deepseek.com',
    [vision('deepseek-v4-flash-vision-exp', 'DeepSeek V4 Flash Vision')],
    '每图计费上限 384 tokens，整页小字需先裁题', 'https://api-docs.deepseek.com/guides/vision'),
  new AiPlatform('xai', 'xAI Grok', 'xAI Grok', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://api.x.ai/v1',
    [vision('grok-4.6', 'Grok 4.6'), vision('grok-4.5', 'Grok 4.5')],
    '各模型页 Modalities: text,image→text', 'https://docs.x.ai/docs/api-reference'),
  new AiPlatform('nvidia-nim', '英伟达 NIM', 'NVIDIA NIM', AiPlatformCategory.CLOUD,
    AiPlatformAccess.DIRECT, 'https://integrate.api.nvidia.com/v1',
    [vision('meta/llama-3.2-11b-vision-instruct', 'Llama 3.2 11B Vision Instruct'),
      vision('nvidia/nemotron-nano-12b-v2-vl', 'Nemotron Nano 12B v2 VL')],
    '自托管形态走 http://<host>:8000/v1', 'https://docs.nvidia.com/nim/'),
  new AiPlatform('cerebras', 'Cerebras', 'Cerebras', AiPlatformCategory.INFERENCE,
    AiPlatformAccess.DIRECT, 'https://api.cerebras.ai/v1',
    [vision('qwen-3.8-27b', 'Qwen 3.8 27B')],
    '仅 base64 data URI、≤10 MiB、免费档 ≤2 图/请求', 'https://inference-docs.cerebras.ai/'),
  new AiPlatform('zhipu', '智谱 BigModel', 'Zhipu BigModel', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://open.bigmodel.cn/api/paas/v4',
    [vision('glm-5.3-flash', 'GLM-5.3 Flash'), vision('glm-4.6v', 'GLM-4.6V')],
    '官方：一次请求不要混放文件/视频/图片', 'https://docs.bigmodel.cn/'),
  new AiPlatform('moonshot', '月之暗面 Kimi', 'Kimi', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://api.moonshot.cn/v1',
    [vision('kimi-k3', 'Kimi K3'), vision('kimi-k2.6', 'Kimi K2.6')],
    '不支持 URL 图片，必须 base64；旧 vision 模型已下线', 'https://platform.moonshot.cn/docs'),
  new AiPlatform('bailian', '阿里云百炼', 'Alibaba Cloud Model Studio', AiPlatformCategory.CLOUD,
    AiPlatformAccess.DIRECT, 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    [vision('qwen3.8-max', 'Qwen3.8 Max'), vision('qwen3.5-ocr', 'Qwen3.5 OCR')],
    '新域名含 {WorkspaceId} 占位，继续用旧域名', 'https://help.aliyun.com/zh/model-studio/'),
  new AiPlatform('stepfun', '阶跃星辰 StepFun', 'StepFun', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://api.stepfun.com/v1',
    [vision('step-3.7-flash', 'Step 3.7 Flash'), vision('step-1o-turbo-vision', 'Step 1o Turbo Vision')],
    '勿用 /step_plan/v1（不支持图像）', 'https://platform.stepfun.com/docs'),
  new AiPlatform('volcengine-ark', '豆包 / 火山方舟', 'Volcengine Ark', AiPlatformCategory.CLOUD,
    AiPlatformAccess.DIRECT, 'https://ark.cn-beijing.volces.com/api/v3',
    [vision('doubao-seed-2-1-pro-260628', 'Doubao Seed 2.1 Pro'),
      vision('doubao-seed-1.6-vision', 'Doubao Seed 1.6 Vision')],
    'Bearer 下可直接填模型名，无需 ep-xxxx', 'https://www.volcengine.com/docs/82379'),
  new AiPlatform('infini', '无问芯穹', 'Infinigence', AiPlatformCategory.CLOUD,
    AiPlatformAccess.DIRECT, 'https://cloud.infini-ai.com/maas/v1',
    [vision('deepseek-ocr-2', 'DeepSeek OCR 2')],
    '仅 base64、单文件 ≤5 MiB；路径是 /maas/v1', 'https://docs.infini-ai.com/'),
  new AiPlatform('minimax', 'MiniMax', 'MiniMax', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://api.minimax.io/v1',
    [vision('MiniMax-M3', 'MiniMax M3')],
    '国内外端点二选一，国内为 https://api.minimax.cn/v1', 'https://platform.minimaxi.com/document/Guides'),
  new AiPlatform('hunyuan', '腾讯混元', 'Tencent Hunyuan', AiPlatformCategory.CLOUD,
    AiPlatformAccess.DIRECT, 'https://api.hunyuan.cloud.tencent.com/v1',
    [vision('hunyuan-vision', 'Hunyuan Vision'), vision('hunyuan-turbos-vision', 'Hunyuan TurboS Vision')],
    '新 TokenHub：https://tokenhub.tencentmaas.com/v1', 'https://cloud.tencent.com/document/product/1729'),
  new AiPlatform('qianfan', '百度千帆', 'Baidu Qianfan', AiPlatformCategory.CLOUD,
    AiPlatformAccess.DIRECT, 'https://qianfan.baidubce.com/v2',
    [vision('ernie-4.5-turbo-vl-preview', 'ERNIE 4.5 Turbo VL Preview')],
    'Bearer 鉴权（Key 形如 bce-v3/ALTAK-…）', 'https://cloud.baidu.com/doc/qianfan/index.html'),
  new AiPlatform('modelscope', '魔搭 ModelScope', 'ModelScope', AiPlatformCategory.INFERENCE,
    AiPlatformAccess.DIRECT, 'https://api-inference.modelscope.cn/v1',
    [vision('Qwen/Qwen3-VL-235B-A22B-Instruct', 'Qwen3-VL 235B A22B Instruct'),
      vision('OpenGVLab/InternVL3_5-241B-A28B', 'InternVL3.5 241B A28B')],
    '出处为官方组织仓库（文档站是空壳 SPA）', 'https://github.com/modelscope'),
  new AiPlatform('huggingface', 'Hugging Face Router', 'Hugging Face Router', AiPlatformCategory.INFERENCE,
    AiPlatformAccess.DIRECT, 'https://router.huggingface.co/v1',
    [vision('zai-org/GLM-4.5V', 'GLM-4.5V'), vision('Qwen/Qwen2.5-VL-3B-Instruct', 'Qwen2.5-VL 3B Instruct')],
    '需 fine-grained token', 'https://huggingface.co/docs/inference-providers/index'),
  new AiPlatform('jina', 'Jina AI', 'Jina AI', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://api.jina.ai/v1',
    [vision('jina-ocr-v1', 'Jina OCR v1'), vision('jina-vlm', 'Jina VLM')],
    '对扫描版数学 PDF 对口', 'https://jina.ai/'),
  new AiPlatform('siliconflow', '硅基流动 SiliconFlow', 'SiliconFlow', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://api.siliconflow.cn/v1',
    [vision('Qwen/Qwen3-VL-32B-Instruct', 'Qwen3-VL 32B Instruct'),
      vision('deepseek-ai/DeepSeek-OCR', 'DeepSeek OCR')],
    '多图与 PDF base64', 'https://docs.siliconflow.cn/cn/userguide/capabilities/multimodal-vision'),
  new AiPlatform('dmxapi', 'DMXAPI', 'DMXAPI', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://www.dmxapi.cn/v1',
    [vision('gpt-4o', 'GPT-4o'), vision('gemini-2.5-flash', 'Gemini 2.5 Flash'),
      vision('doubao-1.5-vision-pro-250328', 'Doubao 1.5 Vision Pro')],
    '官方逐字给出 base64 image_url；国际站 https://www.dmxapi.com/v1', 'https://www.dmxapi.cn/'),
  new AiPlatform('ppio', 'PPIO 派欧云', 'PPIO', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://api.ppio.com/openai/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写（官方有视觉语言模型专章，模型清单未渲染）', 'https://ppio.com/docs'),
  new AiPlatform('fireworks', 'Fireworks AI', 'Fireworks AI', AiPlatformCategory.INFERENCE,
    AiPlatformAccess.DIRECT, 'https://api.fireworks.ai/inference/v1',
    [vision('accounts/fireworks/models/qwen3-vl-235b-a22b-instruct', 'Qwen3-VL 235B A22B Instruct')],
    '官方有 PDF 逐页 base64 多图范例', 'https://docs.fireworks.ai/'),
  new AiPlatform('together', 'Together AI', 'Together AI', AiPlatformCategory.INFERENCE,
    AiPlatformAccess.DIRECT, 'https://api.together.xyz/v1',
    [vision('MiniMaxAI/MiniMax-M3', 'MiniMax M3')],
    'Vision + OpenAI 兼容', 'https://docs.together.ai/docs/openai-api-compatibility'),
  new AiPlatform('openrouter', 'OpenRouter', 'OpenRouter', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://openrouter.ai/api/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写（按实时列表选择 厂商/模型）；额外头可选，不需配置', 'https://openrouter.ai/docs'),
  new AiPlatform('aihubmix', 'AiHubMix', 'AiHubMix', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://aihubmix.com/v1',
    [vision('gemini-3.1-pro-preview', 'Gemini 3.1 Pro Preview')],
    'APP-Code 头可选，本应用不发送；备用地址 https://api.aihubmix.com/v1', 'https://docs.aihubmix.com/'),
  new AiPlatform('cherryin', 'CherryIN', 'CherryIN', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://open.cherryin.net/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写；模型名必须带 厂商/ 前缀',
    'https://docs.cherryin.ai/zh/docs/newapi/openai-compatible-usage/'),
  new AiPlatform('302ai', '302.AI', '302.AI', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://api.302.ai/v1',
    [vision('gpt-4o-mini', 'GPT-4o mini')],
    '大陆备用地址 https://api.302ai.com/v1', 'https://doc.302.ai/'),
  new AiPlatform('tokenflux', 'TokenFlux', 'TokenFlux', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://tokenflux.ai/v1',
    [vision('openai/gpt-4o', 'OpenAI GPT-4o')],
    'Bearer 已确认', 'https://tokenflux.ai/'),
  new AiPlatform('qiniu', '七牛云', 'Qiniu', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://api.qnaigc.com/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写（模型广场多模态，ID 逐字一致）；单次消息体 ≤50 MB',
    'https://developer.qiniu.com/aitokenapi'),
  new AiPlatform('alayanew', '九章智算云', 'AlayaNew', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://token.alayanew.com/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写', 'https://www.alayanew.com/'),
  new AiPlatform('burncloud', 'BurnCloud', 'BurnCloud', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://ai.burncloud.com/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型：OpenAI 通道视觉未证实，请手动填写；有 base64 证据的是 Gemini 原生通道',
    'https://ai.burncloud.com/'),
  new AiPlatform('vercel-ai-gateway', 'Vercel AI Gateway', 'Vercel AI Gateway', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://ai-gateway.vercel.sh/v1',
    [vision('anthropic/claude-sonnet-5', 'Claude Sonnet 5')],
    '模型名须 provider/model', 'https://vercel.com/docs/ai-gateway'),
  new AiPlatform('groq', 'Groq', 'Groq', AiPlatformCategory.INFERENCE,
    AiPlatformAccess.DIRECT, 'https://api.groq.com/openai/v1',
    [vision('meta-llama/llama-4-maverick-17b-128e-instruct', 'Llama 4 Maverick 17B 128E Instruct')],
    'llama-4-scout 已排期弃用', 'https://console.groq.com/docs/openai'),
  new AiPlatform('hyperbolic', 'Hyperbolic', 'Hyperbolic', AiPlatformCategory.INFERENCE,
    AiPlatformAccess.DIRECT, 'https://api.hyperbolic.xyz/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写；base URL 来自 LiteLLM 官方文档', 'https://docs.hyperbolic.xyz/'),
  new AiPlatform('poe', 'Poe', 'Poe', AiPlatformCategory.INFERENCE,
    AiPlatformAccess.DIRECT, 'https://api.poe.com/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写（bot 名）；base URL 来自 LiteLLM 官方文档',
    'https://creator.poe.com/docs/external-applications/openai-compatible-api'),
  new AiPlatform('ocoolai', 'ocoolAI', 'ocoolAI', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://one.ocoolai.com/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写', 'https://docs.ocoolai.com/'),
  new AiPlatform('ph8', 'PH8', 'PH8', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://ph8.co/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写', 'https://ph8.co/'),
  new AiPlatform('lanyun', '蓝耘 LANYUN', 'LANYUN', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://maas-api.lanyun.net/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写（官方自相矛盾）；鉴权按 Bearer 处理', 'https://www.lanyun.net/'),
  new AiPlatform('baichuan', '百川智能', 'Baichuan', AiPlatformCategory.DIRECT,
    AiPlatformAccess.DIRECT, 'https://api.baichuan-ai.com/v1',
    new Array<AiPlatformModel>(),
    '不支持题目识别（content 仅 text/file）', 'https://platform.baichuan-ai.com/docs'),
  new AiPlatform('sophnet', 'SophNet 算能云', 'SophNet', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://www.sophnet.com/api/open-apis',
    new Array<AiPlatformModel>(),
    '不支持题目识别（视觉模型是生成式）', 'https://www.sophnet.com/docs/'),
  new AiPlatform('longcat', 'LongCat 龙猫', 'LongCat', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.DIRECT, 'https://api.longcat.chat/openai/v1',
    new Array<AiPlatformModel>(),
    '不支持题目识别：官方原文「仅支持文本输入」', 'https://longcat.chat/platform/docs/'),
  new AiPlatform('ollama', 'Ollama', 'Ollama', AiPlatformCategory.LOCAL,
    AiPlatformAccess.LOCAL_HTTP, 'http://localhost:11434/v1',
    [vision('qwen3-vl', 'Qwen3-VL'), vision('gemma4', 'Gemma 4'), vision('glm-ocr', 'GLM OCR')],
    '无鉴权，Key 可填占位符', 'https://docs.ollama.com/api/openai-compatibility'),
  new AiPlatform('lmstudio', 'LM Studio', 'LM Studio', AiPlatformCategory.LOCAL,
    AiPlatformAccess.LOCAL_HTTP, 'http://localhost:1234/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写（取决于本地加载的 VLM）；默认无鉴权，可选 Token',
    'https://lmstudio.ai/docs/app/api/endpoints/openai'),
  new AiPlatform('ovms', 'OpenVINO Model Server', 'OpenVINO Model Server', AiPlatformCategory.LOCAL,
    AiPlatformAccess.LOCAL_HTTP, 'http://localhost:8000/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写（取决于部署的 VLM）；REST 8000 / gRPC 9000，另文档化 /v3',
    'https://docs.openvino.ai/2025/model-server/ovms_what_is_openvino_model_server.html'),
  new AiPlatform('gpustack', 'GPUStack', 'GPUStack', AiPlatformCategory.LOCAL,
    AiPlatformAccess.LOCAL_HTTP, 'http://localhost/v1-openai',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写（取决于部署的 VLM）；默认端口 80，/v1-openai 是主路径',
    'https://docs.gpustack.ai/'),
  new AiPlatform('new-api', 'New API（自建网关）', 'New API', AiPlatformCategory.LOCAL,
    AiPlatformAccess.LOCAL_HTTP, 'http://localhost:3000/v1',
    new Array<AiPlatformModel>(),
    '未确认视觉模型，请手动填写（取决于上游渠道）；自建网关，地址按部署自行修改',
    'https://github.com/QuantumNous/new-api'),
  new AiPlatform('azure-openai', 'Azure OpenAI', 'Azure OpenAI', AiPlatformCategory.CLOUD,
    AiPlatformAccess.GATEWAY, '',
    [vision('gpt-5.6-sol', 'GPT-5.6 Sol'), vision('gpt-5.6-terra', 'GPT-5.6 Terra'),
      vision('gpt-5.5', 'GPT-5.5'), vision('gpt-4.1', 'GPT-4.1')],
    '请把地址换成你自己的资源名；经典 api-version 形式本应用不支持',
    'https://learn.microsoft.com/en-us/azure/foundry/openai/api-version-lifecycle'),
  new AiPlatform('vertexai', 'Google Vertex AI', 'Google Vertex AI', AiPlatformCategory.CLOUD,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    '唯一鉴权是 OAuth 短期 token（1 小时过期），非静态 Key',
    'https://cloud.google.com/vertex-ai/generative-ai/docs/openapi/openapi-spec'),
  new AiPlatform('aws-bedrock', 'AWS Bedrock', 'AWS Bedrock', AiPlatformCategory.CLOUD,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    'Bedrock API key 可走 Bearer，但地址含 <区域> 占位，需走「自定义」',
    'https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html'),
  new AiPlatform('copilot', 'GitHub Copilot', 'GitHub Copilot', AiPlatformCategory.CLOUD,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    'GitHub Copilot REST 仅席位/用量/策略管理，无公开推理端点', 'https://docs.github.com/en/copilot'),
  new AiPlatform('github-models', 'GitHub Models', 'GitHub Models', AiPlatformCategory.CLOUD,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    '已于 2026-07-30 整体下线（官方建议迁 Azure AI Foundry）', 'https://docs.github.com/en/github-models'),
  new AiPlatform('perplexity', 'Perplexity', 'Perplexity', AiPlatformCategory.DIRECT,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    '旧 Sonar 为 POST /v1/sonar 且仅支持到 2026-09-27；唯一 /chat/completions 形态是私测白名单的 Router API',
    'https://docs.perplexity.ai/'),
  new AiPlatform('mistral', 'Mistral AI', 'Mistral AI', AiPlatformCategory.DIRECT,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    '报文结构不同：image_url 是字符串而非 {url: …} 对象，需传输层单独改写，本期不直连；Pixtral 系列已退役',
    'https://docs.mistral.ai/'),
  new AiPlatform('mimo', '小米 MiMo', 'Xiaomi MiMo', AiPlatformCategory.DIRECT,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    '官方示例用 api-key 头而非 Bearer；vision 仅 mimo-v2.5（旗舰 pro 不支持）',
    'https://github.com/XiaomiMiMo'),
  new AiPlatform('tencent-ti', '腾讯云 TI-ONE', 'Tencent Cloud TI-ONE', AiPlatformCategory.CLOUD,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    '平台 API 强制 TC3-HMAC-SHA256 签名，与 Bearer 传输层不兼容',
    'https://cloud.tencent.com/document/product/851'),
  new AiPlatform('yi-01ai', '零一万物 01.AI', '01.AI', AiPlatformCategory.DIRECT,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    '平台正在停服（2026-08-03 公告，实测 /v1/models 返回 410 Gone）；可改用百炼托管的 Yi 系列',
    'https://platform.lingyiwanwu.com/docs'),
  new AiPlatform('voyageai', 'VoyageAI', 'VoyageAI', AiPlatformCategory.DIRECT,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    '仅 embeddings/rerank，无 chat 端点', 'https://docs.voyageai.com/'),
  new AiPlatform('xirang', '商汤息壤', 'SenseCore', AiPlatformCategory.CLOUD,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    '未找到官方 OpenAI 兼容端点；商汤现行平台为 SenseNova（https://token.sensenova.cn/v1，可用「自定义」接入）',
    'https://www.sensecore.cn/'),
  new AiPlatform('aionly', 'AIOnly', 'AIOnly', AiPlatformCategory.AGGREGATOR,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    '官方 base URL 未查证（其 API 主机不提供公开文档）', 'https://api.aionly.com/'),
  new AiPlatform('cephalon', '端脑云 Cephalon', 'Cephalon', AiPlatformCategory.CLOUD,
    AiPlatformAccess.GATEWAY, '',
    new Array<AiPlatformModel>(),
    '官方 API 文档未查证（/api 为应用市场页）', 'https://www.cephalon.cloud/')
]

export class AiPlatformCatalog {
  static all(): Array<AiPlatform> {
    return PLATFORMS.slice()
  }

  static count(): number {
    return PLATFORMS.length
  }

  static find(id: string): AiPlatform | null {
    const key: string = id.trim().toLowerCase()
    for (let index: number = 0; index < PLATFORMS.length; index++) {
      if (PLATFORMS[index].id === key) return PLATFORMS[index]
    }
    return null
  }

  static search(keyword: string): Array<AiPlatform> {
    const needle: string = keyword.trim().toLowerCase()
    if (needle.length === 0) return PLATFORMS.slice()
    const matches: Array<AiPlatform> = new Array<AiPlatform>()
    for (let index: number = 0; index < PLATFORMS.length; index++) {
      const platform: AiPlatform = PLATFORMS[index]
      if (platform.id.toLowerCase().indexOf(needle) >= 0 ||
        platform.nameZh.toLowerCase().indexOf(needle) >= 0 ||
        platform.nameEn.toLowerCase().indexOf(needle) >= 0) {
        matches.push(platform)
      }
    }
    return matches
  }

  static byCategory(category: AiPlatformCategory): Array<AiPlatform> {
    const matches: Array<AiPlatform> = new Array<AiPlatform>()
    for (let index: number = 0; index < PLATFORMS.length; index++) {
      if (PLATFORMS[index].category === category) matches.push(PLATFORMS[index])
    }
    return matches
  }
}
