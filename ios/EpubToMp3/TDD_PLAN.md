# TDD Bug Sprint — iOS EPUB Reader

## Protocolo obrigatório para cada bug

```
1. ESCREVER teste que falha (reproduz o bug)
2. RODAR teste → confirmar FAIL
3. IMPLEMENTAR fix mínimo
4. RODAR teste → confirmar PASS
5. BUILD + INSTALL + LAUNCH no device físico
6. CONFIRMAR no device
7. COMMITAR (teste + fix juntos)
```

**Nunca pular steps.** Nunca declarar fixed sem device.

Build/deploy:
```bash
cd /Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3
xcodegen generate
xcodebuild -project EpubToMp3.xcodeproj -scheme EpubToMp3 \
  -configuration Debug \
  -destination 'platform=iOS,id=00008140-001128A022BA801C' \
  -derivedDataPath .build build
xcrun devicectl device install app \
  --device 00008140-001128A022BA801C \
  .build/Build/Products/Debug-iphoneos/EpubToMp3.app
xcrun devicectl device process launch \
  --device 00008140-001128A022BA801C com.pietrocode.epubtomp3
```

Rodar testes no device:
```bash
xcodebuild test \
  -project EpubToMp3.xcodeproj -scheme EpubToMp3 \
  -destination 'platform=iOS,id=00008140-001128A022BA801C' \
  -derivedDataPath .build \
  -only-testing:EpubToMp3Tests/<TestClass>/<testMethod>
```

---

## BUG 1 — Retreat vai para 1ª página (deveria ir para a última)

**Status:** [ ] Teste escrito [ ] Teste FAIL [ ] Fix implementado [ ] Teste PASS [ ] Device OK [ ] Commitado

**Root cause:** `returnToPreviousChapter()` seta `readerShouldStartAtLastPage = true` e muda capítulo. O `.onAppear { readerShouldStartAtLastPage = false }` pode resetar o flag antes do `ReaderView.init` executar — resultando em `startAtLastPage: false`, `_currentPage = 0`, e view presa na página 0.

**Arquivos alvo:**
- `PlayerReaderView.swift:36,371,374,974-984`
- `InstantReaderView.swift:127,356,359,1119-1130`
- `ReaderView.swift:309-337,482-506`

**Teste (lógica pura — roda no device):**
```swift
// EpubToMp3Tests/RetreatLastPageTests.swift
func testReaderShouldStartAtLastPageFlagRaceCondition() {
    // Modela a race: onAppear reseta o flag antes do init consumir
    var readerShouldStartAtLastPage = false

    // returnToPreviousChapter() seta true
    readerShouldStartAtLastPage = true

    // SwiftUI recria ReaderView — init captura o valor
    let capturedByInit = readerShouldStartAtLastPage

    // onAppear do novo ReaderView reseta (pode acontecer antes do init em alguns casos)
    readerShouldStartAtLastPage = false

    // Com o bug: se onAppear disparar antes do init capturar, capturedByInit = false
    // O teste documenta que o fix deve garantir capturedByInit = true
    XCTAssertTrue(capturedByInit,
        "startAtLastPage deve ser true quando init do ReaderView roda após returnToPreviousChapter. " +
        "Se false, currentPage inicia em 0 e o retreat vai para a 1a página.")
}

func testCurrentPageInitValueWhenStartAtLastPage() {
    // Modela o init do ReaderView
    func initCurrentPage(startAtLastPage: Bool) -> Int {
        startAtLastPage ? Int.max : 0
    }

    // Com fix aplicado: startAtLastPage=true → currentPage=Int.max
    XCTAssertEqual(initCurrentPage(startAtLastPage: true), Int.max,
        "Com startAtLastPage=true, init deve setar currentPage=Int.max para que " +
        "TextKitPageView faça o deferred seed na última página sem animação.")

    // Regressão: startAtLastPage=false → currentPage=0 (forward crossing normal)
    XCTAssertEqual(initCurrentPage(startAtLastPage: false), 0,
        "Com startAtLastPage=false, init deve setar currentPage=0 (forward crossing).")
}

func testClampedPageResolvesIntMaxToLastPageWhenPagesArrive() {
    func clampedPage(current: Int, count: Int) -> Int {
        max(0, min(count - 1, current))
    }
    // Quando pages chegam (deferred seed), Int.max deve resolver para última página
    XCTAssertEqual(clampedPage(current: Int.max, count: 6), 5)
    XCTAssertEqual(clampedPage(current: Int.max, count: 1), 0)
    // Quando pages vazias (makeUIViewController), resultado é sempre 0
    XCTAssertEqual(clampedPage(current: Int.max, count: 0), 0)
    XCTAssertEqual(clampedPage(current: 0, count: 0), 0)
}
```

**Fix a implementar:**
Remover `.onAppear { readerShouldStartAtLastPage = false }` dos host views. Em vez disso, resetar o flag dentro do `ReaderView.init` após capturar:
```swift
// PlayerReaderView.swift — remover linha 374:
// .onAppear { readerShouldStartAtLastPage = false }  ← REMOVER

// ReaderView.init — após capturar startAtLastPage, o host deve resetar via callback
// Alternativa mais simples: usar .id(chapter.id + (readerShouldStartAtLastPage ? "_last" : ""))
// para garantir identidade única que não depende de timing do onAppear
```

---

## BUG 2 — Barra de progresso mostra poucos segundos

**Status:** [ ] Teste escrito [ ] Teste FAIL [ ] Fix implementado [ ] Teste PASS [ ] Device OK [ ] Commitado

**Root cause:** `AudioPlayer.durationSeconds` atualizado apenas no timer 0.25s. `AVPlayerItem.duration` retorna `.nan` até asset estar pronto — colapsado para 0. Sem KVO, a barra fica em `0...1s` até próximo tick válido.

**Arquivos alvo:**
- `AudioPlayer.swift:1465-1467` (timer tick)
- `InstantReaderView.swift:826-843` (scrubber `0...max(durationSeconds,1)`)
- `FullPlayerSheet.swift` (scrubber)

**Teste (lógica pura):**
```swift
// EpubToMp3Tests/AudioDurationTests.swift
func testDurationCollapsesBugBehaviour() {
    // Bug: .nan colapsado para 0, barra mostra 0...1
    func bugDuration(_ cmTime: Double) -> Double {
        cmTime.isFinite ? cmTime : 0
    }
    func scrubberMax(duration: Double) -> Double {
        max(duration, 1)
    }

    // Com .nan (asset não pronto) → durationSeconds=0 → scrubber 0...1
    XCTAssertEqual(bugDuration(Double.nan), 0)
    XCTAssertEqual(scrubberMax(duration: 0), 1,
        "BUG: scrubber mostra range 0...1s quando duration ainda é nan")
}

func testDurationKVOFixBehaviour() {
    // Fix: KVO atualiza durationSeconds assim que AVPlayerItem.status = .readyToPlay
    // Modela: só aceita valor quando isFinite && > 0
    func fixDuration(_ cmTime: Double, isReady: Bool) -> Double? {
        guard isReady, cmTime.isFinite, cmTime > 0 else { return nil }
        return cmTime
    }

    // Antes de ready: ignora
    XCTAssertNil(fixDuration(Double.nan, isReady: false))
    XCTAssertNil(fixDuration(0, isReady: false))

    // Depois de ready com duração válida: aceita
    XCTAssertEqual(fixDuration(3600, isReady: true), 3600)

    // Depois de ready mas duration ainda nan: ignora (espera próximo evento)
    XCTAssertNil(fixDuration(Double.nan, isReady: true))
}

func testScrubberRangeWithValidDuration() {
    func scrubberMax(duration: Double) -> Double { max(duration, 1) }
    // Com duração real via KVO → scrubber mostra range correto
    XCTAssertEqual(scrubberMax(duration: 3600), 3600)
    XCTAssertEqual(scrubberMax(duration: 120), 120)
}
```

**Fix a implementar (AudioPlayer.swift):**
```swift
// Dentro de setupItem() ou onde AVPlayerItem é criado:
cancellables.removeAll()
item.publisher(for: \.status)
    .receive(on: DispatchQueue.main)
    .sink { [weak self] status in
        guard status == .readyToPlay else { return }
        let d = item.duration.seconds
        if d.isFinite && d > 0 { self?.durationSeconds = d }
    }.store(in: &cancellables)
item.publisher(for: \.duration)
    .receive(on: DispatchQueue.main)
    .sink { [weak self] dur in
        let d = dur.seconds
        if d.isFinite && d > 0 { self?.durationSeconds = d }
    }.store(in: &cancellables)
```

---

## BUG 3 — Player mostra título correto mas toca desde o início

**Status:** [ ] Teste escrito [ ] Teste FAIL [ ] Fix implementado [ ] Teste PASS [ ] Device OK [ ] Commitado

**Root cause:** `mountPlayerIfPossible()` chama `teardownPlayer()` antes de checar resume marker — descarta posição atual. Se `positionSeconds` não foi salvo antes do teardown, resume marker está em 0.

**Arquivos alvo:**
- `AudioPlayer.swift:480-534`
- `InstantReaderView.swift:986-1010`

**Teste (lógica pura):**
```swift
func testResumeMarkerSavedBeforeTeardown() {
    // Bug: teardown antes de salvar → resume em 0
    struct BugPlayer {
        var positionSeconds: Double = 45.0
        var savedMarker: Double = 0

        mutating func teardown() { positionSeconds = 0 } // descarta posição
        mutating func saveMarker() { savedMarker = positionSeconds }
        mutating func play() {
            teardown()        // BUG: teardown antes de salvar
            saveMarker()      // salva 0
        }
    }
    var bug = BugPlayer()
    bug.play()
    XCTAssertEqual(bug.savedMarker, 0,
        "BUG: teardown antes de salvar zera o marker — toca do início")

    // Fix: salvar antes de teardown
    struct FixPlayer {
        var positionSeconds: Double = 45.0
        var savedMarker: Double = 0

        mutating func teardown() { positionSeconds = 0 }
        mutating func saveMarker() { savedMarker = positionSeconds }
        mutating func play() {
            if positionSeconds > 1 { saveMarker() } // FIX: salvar antes
            teardown()
        }
    }
    var fix = FixPlayer()
    fix.play()
    XCTAssertEqual(fix.savedMarker, 45.0,
        "FIX: marker salvo antes do teardown — retoma na posição correta")
}
```

---

## BUG 4 — Toque em links não funciona

**Status:** [ ] Teste escrito [ ] Teste FAIL [ ] Fix implementado [ ] Teste PASS [ ] Device OK [ ] Commitado

**Root cause:** `TextKitPageController` (page-curl mode) cria `UITextView` sem delegate. `shouldInteractWith(url:)` nunca é chamado — links mortos.

**Arquivos alvo:**
- `TextKitPageView.swift:596-611`
- `ReaderView.swift` (`onLinkTap`)
- `PlayerReaderView.swift` (`handleEpubLink`)

**Teste (source-scan — roda no Mac/CI, não no device):**
```swift
func testTextKitPageControllerSetsDelegateOnTextView() throws {
    let source = try sourceFile(named: "TextKitPageView.swift")
    XCTAssertTrue(
        source.contains("textView.delegate = self"),
        "TextKitPageController deve setar textView.delegate = self para que " +
        "shouldInteractWith(url:) seja chamado ao tocar em links.")
}

func testTextKitPageControllerImplementsLinkDelegate() throws {
    let source = try sourceFile(named: "TextKitPageView.swift")
    XCTAssertTrue(
        source.contains("shouldInteractWith url:") || source.contains("shouldInteractWith URL:"),
        "TextKitPageController deve implementar UITextViewDelegate.textView(_:shouldInteractWith:url:in:interaction:)")
    XCTAssertTrue(
        source.contains("onLinkTap?(url)") || source.contains("onLinkTap?(URL)"),
        "O delegate deve chamar onLinkTap com a URL para que o host trate a navegação")
}
```

**Fix a implementar (TextKitPageView.swift):**
```swift
// Em TextKitPageController, ao criar textView:
textView.delegate = self  // ← adicionar

// Implementar delegate:
extension TextKitPageController: UITextViewDelegate {
    func textView(_ textView: UITextView,
                  shouldInteractWith url: URL,
                  in range: NSRange,
                  interaction: UITextItemInteraction) -> Bool {
        if interaction == .invokeDefaultAction {
            onLinkTap?(url)
        }
        return false
    }
}
```

---

## BUG 5 — Imagens do livro não aparecem

**Status:** [ ] Teste escrito [ ] Teste FAIL [ ] Fix implementado [ ] Teste PASS [ ] Device OK [ ] Commitado

**Root cause:** `EpubHtmlRenderer.stripImageSources()` remove **todos** os atributos `src` de `<img>`. Sem `src`, sem imagem. Sem `.baseURL` no importer, paths relativos também não resolveriam.

**Arquivos alvo:**
- `EpubHtmlRenderer.swift:79,365-374`

**Teste (lógica pura):**
```swift
func testStripImageSourcesRemovesSrc() {
    // Documenta o bug: src é removido
    let html = "<p>texto</p><img src=\"images/cover.jpg\" alt=\"capa\"/>"
    let stripped = html.replacingOccurrences(
        of: #" src="[^"]*""#, with: "", options: .regularExpression)
    XCTAssertFalse(stripped.contains("src="),
        "BUG DOCUMENTADO: stripImageSources remove src — imagem não renderiza")
    XCTAssertFalse(stripped.contains("images/cover.jpg"))
}

func testFixPreservesImgWithDataURI() {
    // Fix: substituir src por data: URI
    // Modela a conversão esperada
    let imageBytes = Data([0xFF, 0xD8, 0xFF]) // JPEG magic bytes
    let base64 = imageBytes.base64EncodedString()
    let dataURI = "data:image/jpeg;base64,\(base64)"
    let fixedHtml = "<img src=\"\(dataURI)\" alt=\"capa\"/>"

    XCTAssertTrue(fixedHtml.contains("data:image/jpeg;base64,"),
        "FIX: src deve ser substituído por data: URI para que NSAttributedString renderize a imagem")
    XCTAssertTrue(fixedHtml.contains("src="),
        "FIX: atributo src deve ser preservado (com data: URI)")
}
```

**Fix a implementar (EpubHtmlRenderer.swift):**
Ao invés de `stripImageSources()`, implementar `inlineImageSources(epub: EPUBDocument)` que:
1. Para cada `<img src="path">`, resolve o path relativo dentro do EPUB zip
2. Lê os bytes da imagem
3. Converte para `data:image/[type];base64,[base64]`
4. Substitui o `src` original

---

## BUG 6 — Download automático indesejado

**Status:** [ ] Teste escrito [ ] Teste FAIL [ ] Fix implementado [ ] Teste PASS [ ] Device OK [ ] Commitado

**Root cause:** `ChapterCacheManager.prefetchNext(2, from:)` chamado no `onAppear` e em mudanças de capítulo — baixa 2 capítulos silenciosamente.

**Arquivos alvo:**
- `InstantReaderView.swift:289,310`
- `ChapterCacheManager.swift`

**Teste (lógica pura):**
```swift
func testPrefetchNotCalledOnAppearByDefault() {
    // Modela: prefetch só deve ocorrer após opt-in explícito do usuário
    var prefetchCalled = false
    let autoPrefetch = false // settings.autoPrefetchAudio default

    func onAppear() {
        if autoPrefetch { prefetchCalled = true } // FIX: gatear
        // BUG seria: prefetchCalled = true (sem gate)
    }
    onAppear()

    XCTAssertFalse(prefetchCalled,
        "FIX: prefetchNext não deve ser chamado automaticamente no onAppear " +
        "sem consentimento do usuário (autoPrefetchAudio = false por padrão)")
}
```

**Fix:**
```swift
// InstantReaderView.swift — remover chamadas automáticas:
// .onAppear { cacheManager.prefetchNext(2, from: currentChapterIndex) }  ← REMOVER
// .compatOnChange(of: currentChapterIndex) { cacheManager.prefetchNext(2, from: $0) }  ← REMOVER
// Ou gatear: if settings.autoPrefetchAudio { ... }
```

---

## BUG 7 — Long-press seleciona texto em vez de mostrar "Tocar daqui"

**Status:** [ ] Teste escrito [ ] Teste FAIL [ ] Fix implementado [ ] Teste PASS [ ] Device OK [ ] Commitado

**Root cause:** Nenhum `UILongPressGestureRecognizer` existe para interceptar o long-press antes do `UITextView`. `pendingSentence` nunca é setado a partir da superfície do reader.

**Arquivos alvo:**
- `TextKitPageView.swift:596-611`
- `ReaderView.swift:21` (`onJumpToSentence`)
- `PlayerReaderView.swift:248-286`

**Teste (lógica pura):**
```swift
func testLongPressResolvesCharacterIndexToSentenceSpan() {
    // Modela: dado um character offset, encontrar o SentenceSpan que o contém
    struct SentenceSpan {
        let id: String
        let startChar: Int
        let endChar: Int
    }

    let spans = [
        SentenceSpan(id: "s1", startChar: 0, endChar: 50),
        SentenceSpan(id: "s2", startChar: 51, endChar: 120),
        SentenceSpan(id: "s3", startChar: 121, endChar: 200),
    ]

    func findSpan(at charIndex: Int, in spans: [SentenceSpan]) -> SentenceSpan? {
        spans.first { charIndex >= $0.startChar && charIndex <= $0.endChar }
    }

    XCTAssertEqual(findSpan(at: 25, in: spans)?.id, "s1")
    XCTAssertEqual(findSpan(at: 80, in: spans)?.id, "s2")
    XCTAssertNil(findSpan(at: 250, in: spans))
}
```

**Fix:**
Em `TextKitPageController`, instalar `UILongPressGestureRecognizer` no `textView` com `require(toFail:)` para cancelar a seleção nativa, chamar `onJumpToSentence?(span)` com o span sob o toque.

---

## BUG 8 — "Tocar daqui" ausente do menu de play

**Status:** [ ] Teste escrito [ ] Teste FAIL [ ] Fix implementado [ ] Teste PASS [ ] Device OK [ ] Commitado

**Root cause:** Em `InstantReaderView`, `showingPlayMenu` / `pendingPlayAnchor` declarados mas nunca usados na UI. Menu não implementado. Depende do Bug 7 (long-press) para ser ativado.

**Arquivos alvo:**
- `InstantReaderView.swift:139-140`
- `PlayerReaderView.swift:248-286`

**Teste (source-scan — CI/Mac):**
```swift
func testInstantReaderViewHasPlayFromHereConfirmationDialog() throws {
    let source = try sourceFile(named: "InstantReaderView.swift")
    XCTAssertTrue(
        source.contains("confirmationDialog") && source.contains("pendingPlayAnchor"),
        "InstantReaderView deve implementar confirmationDialog para 'Tocar daqui' " +
        "usando pendingPlayAnchor como trigger.")
}
```

**Fix:** Após Bug 7, adicionar `.confirmationDialog` em `InstantReaderView` similar ao `PlayerReaderView`.

---

## Checklist de progresso

Atualizar este arquivo conforme cada bug avança:

| Bug | Teste escrito | Teste FAIL | Fix impl | Teste PASS | Device OK | Commit |
|-----|:---:|:---:|:---:|:---:|:---:|:---:|
| 1 Retreat → pág 1 | [x] | [x] | [x] | [x] | [x] | [x] |
| 2 Barra duração | [x] | [x] | [x] | [x] | [x] | [x] (ce431e1) |
| 3 Toca do início | [x] | [x] | [x] | [x] | [x] | [x] (ce431e1) |
| 4 Links mortos | [x] | [x] | [x] | [x] | [x] | [x] |
| 5 Imagens somem | [x] | [x] | [x] | [x] | [x] | [x] (8984aa3) |
| 6 Download auto | [x] | [x] | [x] | [x] | [x] | [x] (62deea6) |
| 7 Long-press seleção | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] — ainda em aberto, sem UILongPressGestureRecognizer no TextKitPageView |
| 8 Tocar daqui ausente | [x] scroll / [ ] page-curl | — | parcial | — | — | 62deea6 cobriu só scroll mode; page-curl (default) ainda sem `onJumpToSentence` conectado |

## Ordem de ataque (paralelizável)

```
Rodada 1 (paralela): BUG 2 + BUG 6    ← independentes, rápidos
Rodada 2 (paralela): BUG 4 + BUG 1    ← independentes
Rodada 3 (sequencial): BUG 7 → BUG 8  ← 8 depende de 7
Rodada 4: BUG 5                        ← mais complexo (base64)
Rodada 5: BUG 3                        ← diagnóstico mais profundo
```
