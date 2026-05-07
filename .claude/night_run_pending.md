# Night-run pending (2026-05-06)

## Out-of-scope items (need user decision)

### Docker build
- `mise run docker:build` falha com `sh: docker: command not found`
- Docker Desktop / `docker` CLI não está instalado nesta máquina
- HF Spaces builds o Docker via CI; localmente não é blocker
- Sugestão: documentar como opcional ou instalar Docker Desktop


## Dependabot major bump (needs user approval)

### PR #158: vite 7.3.2 → 8.0.11 (major)
- Per workflow policy: major bumps require user decision
- Vite 8 may have breaking changes for the React/Vite frontend
- Action: leave open; user reviews changelog before merge
- URL: https://github.com/pietro1704/Epub-to-Mp3/pull/158
