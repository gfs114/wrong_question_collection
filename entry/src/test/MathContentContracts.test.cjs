const fs = require('fs')
const path = require('path')
const vm = require('vm')

const projectRoot = path.resolve(__dirname, '../../..')

function projectPath(relativePath) {
  return path.join(projectRoot, relativePath.replace(/\//g, path.sep))
}

function requireFile(relativePath) {
  const file = projectPath(relativePath)
  if (!fs.existsSync(file)) {
    throw new Error(relativePath + ' is required')
  }
  return fs.readFileSync(file, 'utf8')
}

function expectIncludes(source, text, message) {
  if (!source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

function expectAbsent(source, text, message) {
  if (source.includes(text)) {
    throw new Error(message + ': ' + text)
  }
}

function count(source, text) {
  return source.split(text).length - 1
}

for (const file of [
  'entry/src/main/ets/utils/MathContentUtils.ets',
  'entry/src/main/ets/components/MathContentView.ets',
  'entry/src/main/resources/rawfile/math/math-content.html',
  'entry/src/main/resources/rawfile/math/katex.min.js',
  'entry/src/main/resources/rawfile/math/auto-render.min.js',
  'entry/src/main/resources/rawfile/math/katex.min.css',
  'entry/src/main/resources/rawfile/math/LICENSE'
]) {
  requireFile(file)
}

const html = requireFile('entry/src/main/resources/rawfile/math/math-content.html')
for (const token of [
  'textContent',
  'trust: false',
  'throwOnError: true',
  'reportFailure',
  'reportSuccess',
  'white-space: pre-wrap',
  'overflow-x: auto',
  'ResizeObserver',
  'analyzeDelimiters',
  'isLikelyCurrencyRange',
  'activeGeneration',
  'getBoundingClientRect().height'
]) {
  expectIncludes(html, token, 'local math HTML must implement safe resilient rendering')
}
expectAbsent(html, 'innerHTML', 'question content must never be assigned through innerHTML')

const inlineScripts = Array.from(html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g))
  .map((match) => match[1])
  .filter((source) => source.trim().length > 0)
const rendererScript = inlineScripts[inlineScripts.length - 1]

function createRendererHarness(initialContent, initialGeneration) {
  let content = initialContent
  let generation = initialGeneration
  const rendered = []
  const successReports = []
  const failureReports = []
  const frameCallbacks = []
  const cancelledFrames = new Set()
  const childNodes = []
  let rootText = ''
  const root = {
    style: {},
    scrollHeight: 32,
    appendChild(node) {
      childNodes.push(node)
      return node
    },
    querySelectorAll() {
      return rendered.map(() => ({}))
    },
    getBoundingClientRect() {
      return { height: 32 }
    }
  }
  Object.defineProperty(root, 'textContent', {
    get() {
      return rootText
    },
    set(value) {
      rootText = value
      childNodes.length = 0
    }
  })

  class FakeResizeObserver {
    constructor(callback) {
      this.callback = callback
    }

    observe() {}

    disconnect() {}
  }

  const window = {
    mathBridge: {
      getContent: () => content,
      getFontSize: () => 16,
      getFontWeight: () => 400,
      getTextColor: () => '#111111',
      getLineHeight: () => 24,
      getGeneration: () => generation,
      reportSuccess: (reportedGeneration, height) => {
        successReports.push({ generation: reportedGeneration, height })
      },
      reportFailure: (reportedGeneration) => {
        failureReports.push(reportedGeneration)
      }
    },
    requestAnimationFrame(callback) {
      frameCallbacks.push(callback)
      return frameCallbacks.length
    },
    cancelAnimationFrame(frameId) {
      cancelledFrames.add(frameId)
    },
    addEventListener() {}
  }
  const document = {
    getElementById: () => root,
    createTextNode: (text) => ({ nodeType: 3, textContent: text }),
    createElement: (tagName) => ({ tagName, childNodes: [] })
  }
  const context = {
    window,
    document,
    ResizeObserver: FakeResizeObserver,
    katex: {
      render(math, target, options) {
        if (math.includes('INVALID')) {
          throw new Error('invalid formula')
        }
        rendered.push({ math, target, options })
      }
    },
    renderMathInElement(target, options) {
      rendered.push({ math: 'auto-render', target, options })
    }
  }
  vm.runInNewContext(rendererScript, context)
  return {
    render: () => context.window.renderMathContent(),
    setState(nextContent, nextGeneration) {
      content = nextContent
      generation = nextGeneration
    },
    rendered,
    successReports,
    failureReports,
    childNodes,
    frameCallbacks,
    cancelledFrames
  }
}

const mixedCurrencyHarness = createRendererHarness('价格 $5，公式 $x^2$。', 11)
mixedCurrencyHarness.render()
if (mixedCurrencyHarness.failureReports.length !== 0 || mixedCurrencyHarness.rendered.length !== 1 ||
  mixedCurrencyHarness.rendered[0].math !== 'x^2') {
  throw new Error('currency mixed with math must render only the explicit formula')
}
if (!mixedCurrencyHarness.childNodes.some((node) => String(node.textContent).includes('$5'))) {
  throw new Error('currency text must remain literal during mixed rendering')
}

for (const mixedAsciiCurrency of ['Price $5, solve $x^2$.', 'Price $5, solve $ x^2 $.', '$5 + $x$']) {
  const mixedAsciiHarness = createRendererHarness(mixedAsciiCurrency, 16)
  mixedAsciiHarness.render()
  if (mixedAsciiHarness.failureReports.length !== 0 || mixedAsciiHarness.rendered.length !== 1 ||
    mixedAsciiHarness.rendered[0].math.trim() !== (mixedAsciiCurrency.includes('x^2') ? 'x^2' : 'x')) {
    throw new Error('ASCII currency mixed with math must render only the final explicit formula')
  }
  if (!mixedAsciiHarness.childNodes.some((node) => String(node.textContent).includes('$5'))) {
    throw new Error('ASCII currency text must remain literal during mixed rendering')
  }
}

for (const formulaBeforeCurrency of [
  'Area $2x$ costs $5.',
  'Area $2 x$ costs $5.',
  'Value $2 + 1$ costs $5.',
  'Price $5, area $2x$, cost $10.'
]) {
  const orderedHarness = createRendererHarness(formulaBeforeCurrency, 17)
  orderedHarness.render()
  if (orderedHarness.failureReports.length !== 0 || orderedHarness.rendered.length !== 1 ||
    !['2x', '2 x', '2 + 1'].includes(orderedHarness.rendered[0].math)) {
    throw new Error('formula and currency ordering must not change the parsed formula span')
  }
  if (!orderedHarness.childNodes.some((node) => String(node.textContent).includes('$5'))) {
    throw new Error('surrounding currency must remain literal when a formula renders')
  }
}

const pricesHarness = createRendererHarness('价格从 $5 降到 $4。', 12)
pricesHarness.render()
if (pricesHarness.failureReports.length !== 1 || pricesHarness.rendered.length !== 0) {
  throw new Error('ambiguous currency delimiters must fall back instead of becoming math')
}

const priceRangeHarness = createRendererHarness('价格区间 $5-$10。', 14)
priceRangeHarness.render()
if (priceRangeHarness.failureReports.length !== 1 || priceRangeHarness.rendered.length !== 0) {
  throw new Error('hyphenated prices must fall back instead of becoming math')
}

for (const coefficientFormula of ['$2x$', '$12cm$', '$2x2$', '$2n!$']) {
  const coefficientHarness = createRendererHarness(coefficientFormula, 15)
  coefficientHarness.render()
  if (coefficientHarness.failureReports.length !== 0 || coefficientHarness.rendered.length !== 1) {
    throw new Error(coefficientFormula + ' must remain a valid explicit formula')
  }
}

const malformedHarness = createRendererHarness('残缺公式：$\\frac{x{', 13)
malformedHarness.render()
if (malformedHarness.failureReports.length !== 1 || malformedHarness.rendered.length !== 0) {
  throw new Error('malformed delimiters must report failure')
}

const generationHarness = createRendererHarness('$x^2$', 21)
generationHarness.render()
const firstGenerationSuccesses = generationHarness.successReports.filter((report) => report.generation === 21).length
generationHarness.setState('$y^2$', 22)
generationHarness.render()
generationHarness.frameCallbacks[0]()
if (generationHarness.successReports.filter((report) => report.generation === 21).length !== firstGenerationSuccesses) {
  throw new Error('stale scheduled callbacks must not report an old generation')
}
if (!generationHarness.cancelledFrames.has(1)) {
  throw new Error('a new render must cancel the previous scheduled height measurement')
}

const rawMathRoot = projectPath('entry/src/main/resources/rawfile/math')
const rawFiles = []
function collectFiles(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name)
    if (entry.isDirectory()) {
      collectFiles(full)
    } else {
      rawFiles.push(full)
    }
  }
}
collectFiles(rawMathRoot)
const allowedNamespaceUrls = new Set([
  'http://www.w3.org/1998/Math/MathML',
  'http://www.w3.org/2000/svg'
])
for (const file of rawFiles) {
  const source = fs.readFileSync(file).toString('latin1')
  const urls = source.match(/https?:\/\/[A-Za-z0-9./:_?#=&%-]+/g) || []
  for (const url of urls) {
    if (!allowedNamespaceUrls.has(url)) {
      throw new Error(path.relative(projectRoot, file) + ' must stay fully offline: ' + url)
    }
  }
  for (const remote of ['cdn.jsdelivr.net', 'unpkg.com', 'cdnjs.cloudflare.com']) {
    expectAbsent(source, remote, path.relative(projectRoot, file) + ' must stay fully offline')
  }
}

const css = requireFile('entry/src/main/resources/rawfile/math/katex.min.css')
const fontFiles = css.match(/fonts\/[A-Za-z0-9_-]+\.woff2/g) || []
if (fontFiles.length === 0) {
  throw new Error('KaTeX CSS must reference local WOFF2 fonts')
}

const vendorHashes = new Map([
  ['entry/src/main/resources/rawfile/math/katex.min.js',
    '30c9f7c07bf54d341ffd8f16dc6632766f12b16d0a064e2a08f2d6b1744396a6'],
  ['entry/src/main/resources/rawfile/math/auto-render.min.js',
    'e5372d199bcdae8b4de71d0f7ceba72a4ba12774a27c60a6f1f77d03b3228ee4'],
  ['entry/src/main/resources/rawfile/math/katex.min.css',
    '5bc44ab327592b75fcf2d412a1b396ebf20203bfe826a1966fb8ab03f8b08bb4'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_AMS-Regular.woff2',
    '0cdd387c9590a1a9f9794560022dbb59654a7d86f187aa0c81495ad42d3a7308'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Caligraphic-Bold.woff2',
    'de7701e42cf1f4cf0b766c03fb27977207eee2f4fd5d76fa82188406da43ea4c'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Caligraphic-Regular.woff2',
    '5d53e70ad607c2352162dec9e0923fb54ecdafaccbf604cd8dcf7d00facb989b'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Fraktur-Bold.woff2',
    '74444efd593c005e3f4573b44524704c0af0a937fe911cca9e94068d0d140d3f'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Fraktur-Regular.woff2',
    '51814d270d06ff0255dba0799994fa4d8c84d11f09951d47595f4abb1f3602dc'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Main-Bold.woff2',
    '0f60d1b897938ec918c8ce073092411baf9438f6739465693ff18b0f9d20b021'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Main-BoldItalic.woff2',
    '99cd42a3c072d918f2f44984a807cf7aa16e13545fd0875fc07c6c65f99e715b'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Main-Italic.woff2',
    '97479ca6cce906abc961ecac96faa5f9ca2e61b8e7670d475826bcdee9a7c267'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Main-Regular.woff2',
    'c2342cd8b869e01752a9321dc17213fc40d4d04c79688c1d43f2cf316abd7866'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Math-BoldItalic.woff2',
    'dc47344dbb6cb5b655c8460d561f4df5f501b90c804ad3c6cec65fe322351ab1'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Math-Italic.woff2',
    '7af58c5ec8f132a2ddde9027c6d7814decce4d3b822a11192a42a20e2e973264'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_SansSerif-Bold.woff2',
    'e99ae51144bf1232efcc1bfe5add36262c6866b0faab24fa75740e1b98577a62'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_SansSerif-Italic.woff2',
    '00b26ac825e2095056396e0553b8ac26d3f8ad158c3826e28b4c45b385c4714a'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_SansSerif-Regular.woff2',
    '68e8c73ef42afd3ccec58bf0fba302cce448938e7fc020a5e31f8a952eee1342'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Script-Regular.woff2',
    '036d4e95149b69ff9bcc0cd55771efeb25ffa3947293e69acd78d5ac328c684b'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Size1-Regular.woff2',
    '6b47c40166b6dbe21a5dfca7718413f2147fd2399be1ba605d8ad39cedf25dfe'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Size2-Regular.woff2',
    'd04c54219f9eaec6d4d4fd42dfb28785975a4794d6b2fc71e566b9cd6db842dd'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Size3-Regular.woff2',
    '73d591271b1604960cb10bb90fee021670af7297017e0e98480b332d11f51995'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Size4-Regular.woff2',
    'a4af7d414440a1c1790825cfb700cf9cf43b0f2c4b04f0ebc523011ad9853ec0'],
  ['entry/src/main/resources/rawfile/math/fonts/KaTeX_Typewriter-Regular.woff2',
    '71d517d67827787cfabdf186914cc3358eda539e37931941f2b2fd4a21f68c0b']
])
const crypto = require('crypto')
for (const [relativePath, expectedHash] of vendorHashes) {
  const actualHash = crypto.createHash('sha256').update(fs.readFileSync(projectPath(relativePath))).digest('hex')
  if (actualHash !== expectedHash) {
    throw new Error(relativePath + ' does not match the reviewed KaTeX 0.18.5 distribution')
  }
}
for (const fontFile of new Set(fontFiles)) {
  requireFile('entry/src/main/resources/rawfile/math/' + fontFile)
}

const component = requireFile('entry/src/main/ets/components/MathContentView.ets')
for (const token of [
  'MathContentUtils.containsMath',
  "$rawfile('math/math-content.html')",
  'javaScriptProxy',
  'window.renderMathContent()',
  'onlineImageAccess(false)',
  'domStorageAccess(false)',
  'geolocationAccess(false)',
  'onLoadIntercept',
  'renderReady',
  'renderFailed',
  'webHeight',
  'renderGeneration',
  'getGeneration'
]) {
  expectIncludes(component, token, 'MathContentView must contain the native/Web fallback state machine')
}
expectAbsent(component, '20000', 'dynamic math height must not be silently capped')

for (const relative of [
  'entry/src/main/ets/pages/QuestionDetailPage.ets',
  'entry/src/main/ets/pages/WrongQuestionDetailPage.ets'
]) {
  const source = requireFile(relative)
  expectIncludes(source, "import { MathContentView }", relative + ' must import the shared renderer')
  if (count(source, 'MathContentView({') < 4) {
    throw new Error(relative + ' must render question, options, answer, and analysis through MathContentView')
  }
}

for (const relative of [
  'entry/src/main/ets/components/QuestionCard.ets',
  'entry/src/main/ets/components/WrongQuestionCard.ets'
]) {
  const source = requireFile(relative)
  expectIncludes(source, 'MathContentUtils.toPlainPreview(this.questionText)',
    relative + ' must use a lightweight native preview')
  expectAbsent(source, 'Web(', relative + ' must never create a Web component')
  expectAbsent(source, 'MathContentView', relative + ' must never import the detail renderer')
}

const editPage = requireFile('entry/src/main/ets/pages/EditQuestionPage.ets')
expectIncludes(editPage, 'TextInput(', 'saved question editing must remain a native input')
expectIncludes(editPage, 'TextArea(', 'saved question editing must retain raw multiline input')
expectIncludes(editPage, 'MathContentUtils.containsMath', 'saved question editor must gate math previews')
expectIncludes(editPage, 'MathContentView({', 'saved question editor must use the shared preview renderer')

const reviewPage = requireFile('entry/src/main/ets/pages/PdfImportReviewPage.ets')
expectIncludes(reviewPage, 'TextInput(', 'PDF review must keep raw native inputs')
expectIncludes(reviewPage, 'TextArea(', 'PDF review must keep raw multiline inputs')
expectIncludes(reviewPage, 'previewDraftQuestionId', 'PDF review must expand at most one draft preview')
expectIncludes(reviewPage, 'MathContentUtils.containsMath', 'PDF review must gate math previews')
expectIncludes(reviewPage, 'MathContentView({', 'PDF review must use the shared preview renderer')

const questionModel = requireFile('entry/src/main/ets/models/Question.ets')
for (const field of ['latex:', 'mathml:', 'html:']) {
  expectAbsent(questionModel.toLowerCase(), field, 'Question schema must not add rendered math fields')
}

process.stdout.write('Math content contracts passed\n')
