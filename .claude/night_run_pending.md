# Night-run pending (2026-05-06)

## Out-of-scope items (need user decision)

### Docker build
- `mise run docker:build` falha com `sh: docker: command not found`
- Docker Desktop / `docker` CLI não está instalado nesta máquina
- HF Spaces builds o Docker via CI; localmente não é blocker
- Sugestão: documentar como opcional ou instalar Docker Desktop


## Resolved

### PR #158: vite 7.3.2 → 8.0.11 (major) — MERGED 2026-05-07
- User approved
- Required changes: bump @vitejs/plugin-react to 6, switch
  manualChunks to function form, replace optimizeDeps.esbuildOptions
  with rolldownOptions (Vite 8 = Rolldown by default)
- Verified: build green, 134/134 tests pass
