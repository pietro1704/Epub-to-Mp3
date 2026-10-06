# Bug Sprint — iOS EPUB Reader

> **Status (2026-07-08):** Bugs 1-6 fixed and committed. Bug 7 (long-press
> "Tocar daqui" menu) and Bug 8 (page-curl wiring) still open — see
> `TDD_PLAN.md` for the authoritative checklist with commit hashes.

## Contexto técnico

- Repo: `/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/`
- Device: iPhone `00008140-001128A022BA801C`, bundle `com.pietrocode.epubtomp3`
- Build+deploy obrigatório após cada fix:
  ```bash
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
- **Nunca declarar fixed sem confirmar no device físico.**
- **Nunca usar simulador** (risco de kernel panic no Intel 2018).
- Cada fix: adicionar teste de regressão, commitar separado.

## Fixes já aplicados (não reverter)

- `.id(chapter.id)` nos call sites de `ReaderView` em `PlayerReaderView.swift` e `InstantReaderView.swift`
- `ReaderView.init` seta `_currentPage = State(initialValue: Int.max)` e `_jumpToLastPageForChapterId = "__pending__"` quando `startAtLastPage: true`
- `jumpToLastPageTask` só normaliza quando `currentPage == Int.max`
- `TextKitPageView.swift` deferred seed usa `animated: false` quando `currentPage == Int.max`
- `onAppear` do bloco paginado seta `currentPageChapterId = chapter.id`
- `currentPageChapterId = ""` no `onChange(of: chapter.id)` para suprimir footer no frame de gap

---

## Bugs a corrigir (por prioridade)

### BUG 1 — Retreat vai para 1ª página do capítulo anterior (deveria ir para a última)

**Root cause (confiança: média):**
`returnToPreviousChapter()` em `PlayerReaderView.swift:974` e `InstantReaderView.swift:1119` seta `readerShouldStartAtLastPage = true` e imediatamente muda o capítulo. O `.onAppear { readerShouldStartAtLastPage = false }` (linha 374 em ambos) pode resetar o flag na mesma runloop tick que o `ReaderView.init` executa — resultando em `startAtLastPage: false` e `_currentPage = 0`. O `jumpToLastPageForChapterId = "__pending__"` nunca é seedado, o `onAppear` do `ReaderView` não dispara o task, e o view fica na página 0.

**Diagnóstico adicional necessário:**
- Adicionar `print("startAtLastPage=\(startAtLastPage), currentPage init=\(currentPage)")` no `ReaderView.init` e logar no device para confirmar se `startAtLastPage` chega `false`
- Verificar se `readerShouldStartAtLastPage = false` no `onAppear` está zerando antes ou depois do `ReaderView.init`

**Fix provável:**
Em vez de `@State var readerShouldStartAtLastPage`, passar via `@Binding` ou usar um `UUID` como `.id()` combinado com o `chapter.id` mais um flag de backward — ou simplesmente remover o reset do `onAppear` e resetar apenas quando `startAtLastPage` foi consumido dentro do `ReaderView.init`.

**Arquivos:** `PlayerReaderView.swift:36,371,374,974-984`, `InstantReaderView.swift:127,356,359,1119-1130`, `ReaderView.swift:309-337,482-506`

---

### BUG 2 — Barra de progresso mostra poucos segundos (não a duração real do capítulo)

**Root cause (confiança: alta):**
`AudioPlayer.swift` linha ~1466: `durationSeconds` é atualizado num timer de 0.25s via `item.duration.seconds`. `AVPlayerItem.duration` retorna `.nan` enquanto o asset não está totalmente carregado — colapsado para `0`. Sem KVO em `AVPlayerItem.status` ou `duration`, a barra fica em `0...1` segundos até o próximo tick com valor válido. Em streams remotos ou arquivos grandes, isso pode demorar vários segundos.

**Fix:**
Adicionar KVO em `AVPlayerItem` para `duration` e `status`:
```swift
item.publisher(for: \.duration).sink { [weak self] dur in
    let s = dur.seconds
    if s.isFinite && s > 0 { self?.durationSeconds = s }
}.store(in: &cancellables)
item.publisher(for: \.status).sink { [weak self] status in
    if status == .readyToPlay {
        let s = item.duration.seconds
        if s.isFinite && s > 0 { self?.durationSeconds = s }
    }
}.store(in: &cancellables)
```

**Arquivos:** `AudioPlayer.swift:1465-1467`, `FullPlayerSheet.swift` (scrubber binding), `InstantReaderView.swift:826-843`

---

### BUG 3 — Mini/full player mostra título correto mas toca desde o início

**Root cause (confiança: média):**
`mountPlayerIfPossible()` em `InstantReaderView.swift:986` chama `player.play(snapshot:startingAt:)` que chama `teardownPlayer()` primeiro (linha ~480), descartando a posição atual antes de checar o resume-store (linha ~527: `marker.positionSeconds > 1.0`). Se `mountPlayerIfPossible` é re-chamado (ex: mudança de `hasAudio` ou `snapshot`), o resume marker pode estar em 0 para o capítulo novo — aparece como "toca do início".

**Fix:**
Antes de `teardownPlayer()`, salvar a posição atual no resume-store se `positionSeconds > 1`. Verificar também se `play(snapshot:startingAt:)` em `PlayerReaderView` está sendo chamado múltiplas vezes pelo `bootstrap()` em `onAppear`.

**Arquivos:** `AudioPlayer.swift:480-534`, `InstantReaderView.swift:986-1010`, `PlayerReaderView.swift:728-735`

---

### BUG 4 — Toque em links do livro não funciona (page-curl mode)

**Root cause (confiança: alta):**
`TextKitPageController` (usado no modo page-curl) tem um `UITextView` sem delegate — `UITextViewDelegate.textView(_:shouldInteractWith:url:)` nunca é chamado. O `UITextView` processa o tap internamente mas não há delegate para interceptar e chamar `onLinkTap`.

**Fix:**
Em `TextKitPageView.swift`, no `TextKitPageController`, setar `textView.delegate = self` e implementar:
```swift
func textView(_ textView: UITextView,
              shouldInteractWith url: URL,
              in range: NSRange,
              interaction: UITextItemInteraction) -> Bool {
    if interaction == .invokeDefaultAction {
        onLinkTap?(url)
        return false
    }
    return false
}
```
Também verificar que o `UITextView.isEditable = false` e `isSelectable = true` para que o sistema permita interação com links.

**Arquivos:** `TextKitPageView.swift:596-611` (TextKitPageController), `ReaderView.swift` (`onLinkTap` closure), `PlayerReaderView.swift` (`handleEpubLink`), `InstantReaderView.swift` (`handleEpubLink`)

---

### BUG 5 — Imagens do livro não aparecem

**Root cause (confiança: alta):**
`EpubHtmlRenderer.swift` linha ~79 chama `stripImageSources()` (linha ~365) que remove **todos** os atributos `src` de `<img>` e `xlink:href` de `<image>` antes de passar o HTML para o `NSAttributedString` importer. Adicionalmente, o importer não recebe `.baseURL` nas options, então mesmo que `src` fosse preservado, paths relativos não resolveriam.

**Fix (duas partes):**
1. Em `stripImageSources()`: ao invés de remover `src`, converter imagens para `data:` URI (base64) usando os bytes da imagem do EPUB zip. Ou, se performance for problema, substituir por um placeholder `<img>` com dimensões conhecidas.
2. Passar `.baseURL` apontando para o diretório de recursos do EPUB ao construir o `NSAttributedString`.

**Arquivos:** `EpubHtmlRenderer.swift:79,365-374`

---

### BUG 6 — Download começa automaticamente

**Root cause (confiança: média):**
`InstantReaderView.swift` linhas ~289 e ~310: `ChapterCacheManager.prefetchNext(2, from:)` é chamado no `onAppear` e toda vez que o capítulo muda — baixa silenciosamente os próximos 2 capítulos de áudio sem consentimento.

**Fix:**
Remover `prefetchNext` automático ou gateá-lo em uma preferência de usuário `settings.autoPrefetchAudio` (default `false`). Alternativamente, disparar apenas quando o usuário iniciar o playback explicitamente.

**Arquivos:** `InstantReaderView.swift:289,310`, `ChapterCacheManager.swift`

---

### BUG 7 — Long-press no texto seleciona texto em vez de mostrar "Tocar daqui"

**Root cause (confiança: alta):**
Não existe nenhum `UILongPressGestureRecognizer` em `TextKitPageView.swift` nem em `AttributedPageView.swift` para interceptar o long-press antes do `UITextView`. O `UITextView` com `isSelectable = true` captura o long-press nativamente para seleção de texto. `pendingSentence` em `PlayerReaderView` nunca é setado a partir da superfície do reader.

**Fix:**
Em `TextKitPageController` (TextKitPageView.swift), adicionar `UILongPressGestureRecognizer` com `minimumPressDuration: 0.5` no `UITextView`. No handler:
1. Encontrar o `SentenceSpan` que contém o character index sob o toque usando `UITextView.characterIndex(for:)`
2. Chamar `onJumpToSentence?(span)` do `ReaderView` que propaga para `pendingSentence = span` no host
3. Retornar `false` do recognizer para que o `UITextView` NÃO processe o long-press (via `require(toFail:)` ou cancelando a seleção)

**Arquivos:** `TextKitPageView.swift:596-611`, `ReaderView.swift:21` (`onJumpToSentence`), `PlayerReaderView.swift:248-286` (dialog `pendingSentence`), `InstantReaderView.swift:139-140`

---

### BUG 8 — "Tocar daqui" não aparece / opção ausente no menu de play

**Root cause (confiança: alta):**
Em `InstantReaderView.swift`: `showingPlayMenu` e `pendingPlayAnchor` estão declarados (linhas 139-140) mas nenhum código seta `showingPlayMenu = true` nem `pendingPlayAnchor = someSpan` a partir da UI. O menu simplesmente não existe no `InstantReaderView`. Em `PlayerReaderView`: o `confirmationDialog(pendingSentence)` existe (linhas 248-286) mas como Bug 7 mostra, nada seta `pendingSentence` a partir do reader.

**Fix:**
1. Completar o Bug 7 (long-press → `pendingSentence`)
2. Em `InstantReaderView`: implementar o `confirmationDialog` similar ao `PlayerReaderView`, com "Tocar daqui" gateado em `playerMounted || embeddedAudioReady`
3. Adicionar "Tocar daqui" também no menu de play (`showingPlayMenu`) já existente

**Arquivos:** `InstantReaderView.swift:139-140,248+`, `PlayerReaderView.swift:248-286`

---

## Ordem de ataque recomendada

| Prioridade | Bug | Motivo |
|---|---|---|
| 1 | BUG 2 (duração barra) | Uma linha de KVO, alto impacto imediato |
| 2 | BUG 1 (retreat página) | Race condition estreita, fix de flag |
| 3 | BUG 4 (links) | Alta confiança, fix localizado |
| 4 | BUG 6 (download auto) | Remove comportamento indesejado |
| 5 | BUG 5 (imagens) | Requer base64 encoding — mais trabalho |
| 6 | BUG 7 (long-press) | Novo recognizer, precisa de hit-test cuidadoso |
| 7 | BUG 8 (tocar daqui) | Depende do Bug 7 |
| 8 | BUG 3 (posição áudio) | Requer diagnóstico mais profundo |

## Regras obrigatórias

- Diagnosticar causa antes de fixar (nunca patchear sintoma)
- Para cada fix: criar teste de regressão (lógica pura se possível, source-scan como fallback)
- Build → install → launch → confirmar no device antes de declarar resolvido
- Um commit por bug
- Paralelize bugs independentes em subagentes separados (BUG 2 e BUG 4 são independentes entre si e podem atacar em paralelo)
