# Plano de continuidade — Reader, resume e layout EPUB

Atualizado em 2026-07-17.

## Objetivo

- `Paginated` como modo padrão e primeira opção do segmented controller.
- Persistir preferências do Reader.
- Persistir posição de leitura por livro e restaurá-la ao reabrir.
- Se o áudio estava pausado, reabrir pausado.
- Se o áudio estava tocando, reabrir aproximadamente 15 s antes da última posição.
- Renderizar HTML/CSS EPUB preservando o layout real do livro, especialmente *The Lord of the Rings*.

## Estado já implementado

### Preferência de layout

Arquivos principais:

- `ios/EpubToMp3/EpubToMp3/Models/AppSettings.swift`
- `ios/EpubToMp3/EpubToMp3/Views/ReaderSettingsSheet.swift`

Já confirmado:

- `ReaderLayout` está ordenado como `.paginated`, `.scrolling`.
- O fallback de instalação nova é `.paginated`.
- `readerLayout` é salvo em `UserDefaults`.
- A preferência existente do usuário é preservada.

### Posição do Reader

Arquivos:

- `ios/EpubToMp3/EpubToMp3/Services/ReaderCoordinator.swift`
- `ios/EpubToMp3/EpubToMp3/Views/InstantReaderView.swift`
- `ios/EpubToMp3/EpubToMp3/Views/ReaderView.swift`

Implementado localmente:

- `ReaderCoordinator` mantém posição por `bookId`.
- Salva capítulo, `pageRatio` e `sentenceId` em UserDefaults/App Group.
- A página inicial é reconstruída a partir da fração do capítulo, resistindo a repaginação por fonte/orientação.
- O capítulo continua compatível com o mecanismo antigo de `AppSettings`.
- O fallback plain-text agora usa justificação, recuo de primeira linha e espaçamento de parágrafo.

Decisão: UserDefaults + manager próprio é suficiente; SwiftData seria excesso para poucos marcadores pequenos e frequentes.

### Resume do áudio

Arquivos:

- `ios/EpubToMp3/EpubToMp3/Services/ResumeStore.swift`
- `ios/EpubToMp3/EpubToMp3/Services/AudioPlayer.swift`
- `ios/EpubToMp3/EpubToMp3/Views/BookOpenView.swift`
- `ios/EpubToMp3/EpubToMp3/Views/InstantReaderView.swift`

Implementado localmente:

- `ResumeMarker` agora guarda `wasPlaying`.
- Compatibilidade de decoding com marcadores antigos sem esse campo.
- Posição tocando é salva com recuo de 15 s, com clamp em zero.
- Posição pausada é salva exatamente.
- Reabertura só arma bootstrap automático quando `wasPlaying == true`.
- Retomada explícita é marcada separadamente para não fazer um Play manual ressuscitar marcador antigo.
- Segment mode aceita posição de resume pendente.

### Layout HTML/CSS do LOTR

Causa raiz confirmada pelos especialistas:

O parser Python aceitava somente:

```html
<link rel="stylesheet" href="..."><!-- ordem específica -->
```

O EPUB real do LOTR usa também:

```html
<link href="..." rel="stylesheet" type="text/css">
```

Consequência: o CSS inteiro chegava vazio ao iOS.

Correção local:

- `python_app/src/ebook_reader.py` agora faz parsing de atributos da tag `<link>` em qualquer ordem.
- Folhas `rel="alternate stylesheet"` são ignoradas.
- `EpubHtmlRenderer` aplica estilos estruturais por tag/classe, incluindo `text-indent`, margens e espaçamento.
- Matching de classe é exato: `.atx` não casa com `.atx-new`.
- CSS mínimo é fornecido somente quando o EPUB não possui CSS.
- Fallback HTML/plain-text preserva parágrafos e alinhamento justificado.

Classes reais do LOTR consideradas:

- `.atx`: recuo de 20 pt.
- `.atx-new`: recuo de 10 pt.
- `.atxq`: recuo negativo de 20 pt para citações.
- `.cotx`: primeiro bloco sem recuo e com espaço superior.
- `.spb`: novo bloco narrativo com recuo.
- `.p1`: sem recuo e com espaçamento.
- `.cn`/`.ct`: títulos sem recuo, com hierarquia visual.

## Testes adicionados/alterados

- `EpubHtmlRendererTests`: classes `.atx`, `.atxq`, `.atx-new`, `.p1`.
- `test_ebook_reader.py`: ordem variável dos atributos em `<link>`.
- `ReaderAudioFollowingDomainTests`: posição namespaced por livro e estado de resume.
- `AudioPlayerUXTests`: recuo de 15 s quando tocando e posição exata quando pausado.

## Validações já realizadas

- Parser/server Python relevante: 161 testes — PASS.
- `py_compile`: PASS.
- Build host Swift: PASS.
- `git diff --check`: PASS.

## Estado atual (retomada em 2026-07-17)

- Xcode 26.3 possui o SDK iOS 26.2, mas não há runtime de Simulator instalado.
- O destino físico continua inelegível para o fluxo normal por exigir o componente de plataforma do device.
- Sem baixar o pacote de Simulator, foi usado o build direto `-sdk iphoneos -arch arm64`, com remoção temporária e restaurada da fase de `Assets.xcassets` para contornar o erro do `actool`.
- Build físico concluído: `** BUILD SUCCEEDED **`.
- App instalado no iPhone: `com.pietrocode.epubtomp3`.
- App aberto no iPhone com sucesso.
- O `project.pbxproj` foi restaurado e não ficou alterado pelo workaround.
- Python: 161 testes passaram.
- Teste Swift host amplo ainda não fecha porque o target tenta compilar catálogo de assets sem runtime de Simulator; isso não é falha funcional confirmada.

## Próximas etapas

1. Testar manualmente no iPhone com o EPUB real LOTR:
   - abrir capítulo `The Shadow of the Past`;
   - confirmar título e layout;
   - confirmar texto justificado;
   - confirmar recuo de primeiro parágrafo conforme classe;
   - alternar Paginated/Scrolling;
   - fechar e reabrir no mesmo capítulo/página;
   - fechar lendo somente com áudio pausado;
   - fechar enquanto ouvindo;
   - reabrir e confirmar retomada ~15 s antes;
   - pausar e confirmar que não há áudio residual.
2. Corrigir qualquer regressão reproduzida no device, com teste antes do patch.
3. Executar os testes Swift focados no host usando o mesmo workaround, quando necessário.
4. Revisar diff completo e fazer commits separados:
   - persistência/resume;
   - parsing/layout EPUB.
5. Push para `origin/master` somente após o gate físico.

## Comandos de retomada

```bash
cd ~/Developer/Epub-to-Mp3

# Python
./.venv/bin/python -m pytest python_app/tests/test_ebook_reader.py python_app/tests/test_server_conversion.py python_app/tests/test_server_helpers.py -q

# Build host Swift
cd ios/EpubToMp3
xcodebuild -project EpubToMp3.xcodeproj -scheme EpubToMp3 \
  -destination 'platform=macOS' \
  -derivedDataPath ./.build-reader-final build

# Estado do device
xcrun devicectl list devices
```

## Arquivos com alterações locais ainda não commitadas

- `ios/EpubToMp3/EpubToMp3/Services/AudioPlayer.swift`
- `ios/EpubToMp3/EpubToMp3/Services/EpubHtmlRenderer.swift`
- `ios/EpubToMp3/EpubToMp3/Services/ReaderCoordinator.swift`
- `ios/EpubToMp3/EpubToMp3/Services/ResumeStore.swift`
- `ios/EpubToMp3/EpubToMp3/Views/BookOpenView.swift`
- `ios/EpubToMp3/EpubToMp3/Views/InstantReaderView.swift`
- `ios/EpubToMp3/EpubToMp3/Views/ReaderView.swift`
- testes correspondentes.
