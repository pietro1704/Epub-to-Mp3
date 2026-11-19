# Deploy e Hugging Face Spaces

O `Dockerfile` da raiz compila o cliente web Rails: a árvore de runtime Rust/WASM
é compilada em um estágio de build, e a imagem Ruby final contém as gems, a
aplicação, os assets pré-compilados e o runtime gerado (sem Node, toolchain Rust,
`converter-server` nem pesos de modelo). O Space é publicado a partir de um
snapshot de `scripts/hf_snapshot.rb` (`.hf-runtime` é `rails`). Inspecione a
revisão implantada e o workflow antes de diagnosticar serviço hospedado.

A imagem serve na porta 7860 e responde `/api/health` (e `/health`) localmente.
São valores no código, não comprovação de serviço acessível. A interface Rails
não precisa de estado no servidor; qualquer armazenamento em `PERSISTENT_ROOT`
vale apenas para a API de compatibilidade opcional. Sobreviver a reinícios exige volume persistente real e paths/permissões corretos.
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
