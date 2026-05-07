# Night Run Summary — 2026-05-06 → 2026-05-07

## Estado final
**TUDO VERDE.** App 100% deployado.

| Workflow | Conclusion |
|---|---|
| CI | ✅ success |
| Sync to Hugging Face Space | ✅ success |
| Auto Release | ✅ success |
| Release Desktop (9/9 jobs) | ✅ success |
| Automatic Dependency Submission | ✅ success |

Release Desktop matrix completo:
- macos-arm64 ✅
- linux-x64 ✅
- windows-x64 ✅
- android ✅
- ios ✅
- docker ✅
- Update Homebrew cask ✅
- Update Winget manifest ✅
- Generate latest.json ✅

## Commits aplicados (em ordem)

1. **e423543** — `ci(sync-hf): exclude flutter_app from HF Space snapshot`
   - Fix: Flutter AppIcon PNG binário rejeitado pelo HF
   - Adiciona `--exclude "flutter_app"` no rsync

2. **478078b** — `chore(flutter): drop ios/macos targets, pin android toolchain` (feito pelo usuário em outra sessão antes da noite)
   - Decisão: SwiftUI nativo iOS, Flutter SÓ Android
   - Remove `flutter_app/ios/` e `flutter_app/macos/`

3. **4660a87** — `fix(validate): raise normalize_title_key limit 80→160; align Tauri 2.11`
   - Fix Piranesi: false-positive de "Missing cache files" em capítulos hierárquicos longos
   - `normalize_title_key(limit=80)` truncava títulos antes do match → falhava substring
   - Aumentou limit para 160; regression test em `test_validate_conversion.py`
   - Também: `desktop/package.json` pinning `@tauri-apps/api@2.11` para casar Cargo

4. **6eb8dd5** — `ci(release-desktop): scope mise install_args per matrix`
   - Tentativa #1: limitar mise install args (insuficiente)

5. **a06f062** — `ci(release-desktop): disable mise tools per job via MISE_DISABLE_TOOLS`
   - Tentativa #2: env var por job. Funcionou para android-sdk

6. **a9e982a** — `ci(release-desktop): include tauri-cli + git-cliff in mise install_args`
   - Tentativa #3: re-incluir `npm:@tauri-apps/cli` e `cargo:git-cliff` que tinham sido excluídos.
   - **Resolveu definitivamente.** Release Desktop verde.

## Diagnóstico Piranesi (resolvido)

Conversão completou os 20 capítulos com sucesso. Erro era 100% falso positivo da `validate_conversion.py`:
- Capítulos fantasma 6.9 / 8.12 / 9.14 não existem no EPUB (eram artefatos de invocação cruzada com epub diferente via fuzzy match)
- Size mismatch 345k vs 175k: `complete.txt` tinha pre-tts text expandido com headings, EPUB total era texto raw
- Root cause real: `normalize_title_key(limit=80)` truncava título antes do match → fix em 4660a87

Memória: ver `feedback_validate_conversion_title_truncation.md` (a criar quando relevante).

## Pending (out-of-scope autônomo)

- **Docker local CLI ausente** — `mise run docker:build` falha localmente porque não há `docker` no PATH. HF e CI usam Docker, então não é blocker. Documentado em `.claude/night_run_pending.md`. Decisão de instalação é do usuário.

## Builds locais validados

- ✅ Desktop build (mac local, em `b3qkdcppm`)
- ✅ Mobile web bundle
- ✅ Desktop web bundle
- ✅ Flutter analyze
- ✅ Flutter tests
- ✅ Flutter Android APK
- ✅ Full pytest suite (581+ tests)
- ❌ Docker local (sem CLI; documentado)

## Tags e releases

Tag `v0.3.28` re-trigger via `gh workflow run release-desktop.yml -f tag=v0.3.28 -f checkout_ref=master`.
Auto Release detectou commits e bumpou — Release Desktop teve sucesso completo, incluindo:
- Homebrew cask publicado
- Winget manifest atualizado
- latest.json gerado para auto-update do Tauri

## Loop encerrado em 2026-05-07 ~08:55 UTC

Não há mais nada para auto-fixar. App em estado healthy. ScheduleWakeup terminado.

## Verificação pós-encerramento (2026-05-07 ~13:34 UTC)

Confirmado que todos os 7 workflows do commit `c9b0175` (summary docs) passaram:
- CI ✅
- Push on master ✅
- Automatic Dependency Submission (Python) ✅ (após rerun — a 1ª attempt falhou por flake transitória da API GitHub Dependency Graph)
- Auto Release ✅
- Sync to Hugging Face Space ✅
- Release Desktop ✅ (rolling rebuild v0.3.28)
- CI failure diagnose ✅ (skipped, esperado)

Estado final: **app 100% verde, deployado, todos artefatos publicados**.
