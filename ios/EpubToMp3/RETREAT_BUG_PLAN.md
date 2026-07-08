# Plano de Correção: Retreat vai para 1ª página em vez da última

> **Status (2026-07-08): CORRIGIDO.** Este bug (Bug 1 do `TDD_PLAN.md`) está
> fixado e commitado. Documento mantido como referência histórica da causa
> raiz — não reverter os fixes descritos abaixo.

## Status dos fixes já aplicados (não reverter)

- `.id(chapter.id)` nos call sites de `ReaderView` em `PlayerReaderView.swift` (~linha 368) e `InstantReaderView.swift` (~linhas 354 e 374)
- `ReaderView.init` seta `_currentPage = State(initialValue: Int.max)` e `_jumpToLastPageForChapterId = State(initialValue: "__pending__")` quando `startAtLastPage: true`
- `jumpToLastPageTask` só seta `currentPage` quando `currentPage == Int.max`
- `onAppear` do bloco paginado seta `currentPageChapterId = chapter.id`
- `onAppear` principal kick do `jumpToLastPageTask` quando `"__pending__"`
- `currentPageChapterId = ""` no `onChange(of: chapter.id)` para suprimir footer no frame de gap

---

## Diagnóstico definitivo da causa raiz

Sequência exata com `.id(chapter.id)` + `startAtLastPage: true`:

1. Host seta `readerShouldStartAtLastPage = true`, muda o capítulo
2. SwiftUI recria `ReaderView` via `.id(novo_chapter.id)` → `init` roda:
   - `_currentPage = Int.max`
   - `_jumpToLastPageForChapterId = "__pending__"`
3. **`makeUIViewController` roda com `pages = []`** (paginação não terminou ainda):
   - `clampedPage = max(0, min(pages.count-1, Int.max)) = max(0, min(-1, Int.max)) = 0`
   - → seed na **página 0** ← BUG RAIZ
   - `committedChapterToken = nil` (pages vazias)
4. Páginas chegam → `updateUIViewController` linha ~165:
   - `committedChapterToken(nil) != chapterToken` → deferred seed
   - `target = clampedPage = pages.count - 1` (correto agora que pages não é vazio)
   - `seedCrossing(pvc, vc)` → **anima** de página 0 → última ← "forced forward hop"
5. `pendingCrossingDirection` pode ser `.reverse` (armado pelo swipe) ou `nil`
   - Se `nil` → `seedCrossing` faz `animated: false` mas ainda sai de página 0

**Conclusão:** `makeUIViewController` sempre seed página 0 quando `pages = []`. O deferred seed corrige para a última página, mas `seedCrossing` anima — usuário vê a navegação forward indesejada.

---

## Fix a aplicar

### `TextKitPageView.swift` — deferred seed sem animação quando `currentPage == Int.max`

Na condição `committedChapterToken != chapterToken && !pages.isEmpty` (~linha 165):

```swift
if coordinator.committedChapterToken != chapterToken, !pages.isEmpty {
    coordinator.committedChapterToken = chapterToken
    coordinator.isAwaitingChapterSwap = false
    let vc = coordinator.controller(for: target)
    // Backward crossing (startAtLastPage): currentPage == Int.max means
    // makeUIViewController already seeded page 0 (pages were empty at that
    // point). The chapter-curl already happened via the swipe gesture;
    // we just need a hard cut to the last page with no additional animation.
    // seedCrossing would animate from page 0 → last — visible forward hop.
    if currentPage == Int.max {
        pvc.setViewControllers([vc], direction: .forward, animated: false)
    } else {
        coordinator.seedCrossing(pvc, vc)
    }
    return
}
```

### Nenhuma outra mudança necessária

O `init` já seta `_currentPage = Int.max` corretamente.
O `jumpToLastPageTask` já normaliza `Int.max → pages.count - 1` sem navegar.
O `onAppear` já faz o kick do task.

---

## Testes de regressão a adicionar em `BookOpenViewPriorityTests.swift`

```swift
/// FAILS se TextKitPageView deferred seed usa seedCrossing (animado) quando
/// currentPage == Int.max. Com .id(chapter.id), makeUIViewController já seedou
/// página 0 (pages estavam vazias → clampedPage=0). Quando pages chegam o
/// deferred seed deve cortar direto pra última página (animated:false), NÃO animar.
func testTextKitPageViewDeferredSeedSkipsAnimationForIntMaxCurrentPage() throws {
    let source = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Views/TextKitPageView.swift"),
        encoding: .utf8
    )
    XCTAssertTrue(
        source.contains("if currentPage == Int.max {"),
        "TextKitPageView deferred seed deve checar currentPage == Int.max para pular a animação seedCrossing em backward crossings."
    )
}
```

---

## Sequência de verificação

```bash
cd /Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3

# 1. Aplicar o fix em TextKitPageView.swift (bloco deferred seed ~linha 165)

# 2. Build
xcodegen generate
xcodebuild \
  -project EpubToMp3.xcodeproj \
  -scheme EpubToMp3 \
  -configuration Debug \
  -destination 'platform=iOS,id=00008140-001128A022BA801C' \
  -derivedDataPath .build \
  build

# 3. Install + Launch
xcrun devicectl device install app \
  --device 00008140-001128A022BA801C \
  .build/Build/Products/Debug-iphoneos/EpubToMp3.app
xcrun devicectl device process launch \
  --device 00008140-001128A022BA801C \
  com.pietrocode.epubtomp3

# 4. Testar no device:
#    - Capítulo A (múltiplas páginas) → swipe para capítulo B
#    - Na 1ª página do capítulo B → swipe backward
#    - ESPERADO: cai diretamente na ÚLTIMA página do capítulo A, sem nenhuma
#      animação extra de navegação
#    - Se ainda falhar: adicionar logging em TextKitPageView para ver
#      currentPage no momento do deferred seed
```

---

## Outros bugs conhecidos (resolvidos nesta sessão)

| Bug | Fix |
|-----|-----|
| Flicker 77/77 → 1/6 | `.id(chapter.id)` nos call sites |
| Indicadores de página sumiram | `onAppear` seta `currentPageChapterId = chapter.id` |
| Retreat vai pra 1ª página | `_currentPage = Int.max` no `init` |
| Retreat força hop animado pra frente | Deferred seed usa `animated:false` quando `currentPage == Int.max` |
