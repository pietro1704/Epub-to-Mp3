# Deploy e Hugging Face Spaces

O `Dockerfile` atual compila React/Vite e `converter-server` Rust, depois executa
o binário em imagem Debian mínima. `hf_app.py` é legado, não entrada do container
de produção. Inspecione revisão implantada, modo do cliente e workflow antes de
diagnosticar serviço hospedado.

O container declara `PORT=7860`, `HOST=0.0.0.0` e
`PERSISTENT_ROOT=/data/epub-to-mp3`, com healthcheck em `/api/health`. São valores
no código, não comprovação de serviço acessível ou armazenamento persistente.
Sobreviver a reinícios exige volume persistente real e paths/permissões corretos.
Preserve cache, saídas, jobs e dados do usuário.

R2/object storage é opcional e não está comprovado por este repositório. Consulte
[a referência condicional R2](../../R2_SETUP.md) antes de propor integração;
secrets antigos, URLs públicas e endpoint de limpeza local não comprovam uploads,
TTL, exclusão agendada ou gratuidade.

Inspecione `.github/workflows/sync-hf.yml`, workflows de release e o SHA integrado
validado quando publicação for explicitamente solicitada. Entregar branch no
GitHub não autoriza push Hugging Face, publicação de site, mudança de secrets/
configuração, reboot ou rollback. Factory reboot não é diagnóstico padrão.
Use logs/status somente de leitura quando autorizado e informe estado desconhecido.
Editar estas páginas locais não configura serviço, publica wiki ou faz deploy.
