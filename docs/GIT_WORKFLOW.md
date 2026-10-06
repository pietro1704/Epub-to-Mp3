# Git Workflow - Branches e Deploy

## Regra de Integridade

Antes de qualquer push para `master`, reconcilie o repositório local com o remoto:

```bash
git fetch origin
git status -sb
git log --oneline HEAD..origin/master
```

Se houver commits remotos, integre-os com `git pull --rebase origin master` ou faça
um merge deliberado. Nunca faça force-push em `origin/master`.

Depois de cada push para o GitHub, acompanhe os checks até terminarem:

```bash
gh run list --branch master --limit 10
gh run view <run-id> --log-failed
```

Uma alteração não está concluída enquanto os workflows obrigatórios não estiverem
verdes. Workflows opcionais que dependem de segredos devem ser ignorados quando o
segredo não estiver configurado, nunca falhar de propósito.

## Status Atual

### Branches Configuradas

- **GitHub**: Usa `master` como branch principal
- **Hugging Face**: Usa `main` como única branch

### Configuração Automática

O repositório está configurado para **sincronizar automaticamente** `master` → `main` no Hugging Face.

Quando você faz:
```bash
git push huggingface
```

O Git automaticamente:
1. Envia `master` local para `refs/heads/main` no HF

A branch fica **sincronizada** automaticamente.

## Workflow de Deploy

### Método Recomendado (Automático)

```bash
# 1. Fazer commit normalmente
git add -A
git commit -m "Sua mensagem"

# 2. Push para GitHub e HuggingFace
git push origin master && git push huggingface
```

Isso irá:
- ✅ Enviar para GitHub (branch `master`)
- ✅ Enviar para HF (branch `main` sincronizada com `master`)
- ✅ HF Space fará rebuild automático

### Método Alternativo (Manual)

Se preferir usar URLs diretas:

```bash
git push origin master
git push https://huggingface.co/spaces/pi1704/epub-to-mp3 master:main
```

## Verificação

Para verificar se as branches estão sincronizadas:

```bash
git ls-remote huggingface
```

Você deve ver apenas a branch `main`:
```
74ce019... refs/heads/main
```

## Por que Apenas uma Branch no HF?

A configuração atual é mais limpa:

1. ✅ HF usa `main` (convenção padrão)
2. ✅ GitHub usa `master` (sua preferência)
3. ✅ Sync automático mantém ambas atualizadas
4. ✅ Menos confusão (sem branches duplicadas)

## Troubleshooting

### Erro: "remote.huggingface.push has multiple values"

Resetar configuração:
```bash
git config --local --unset-all remote.huggingface.push
git config --local --add remote.huggingface.push '+refs/heads/master:refs/heads/main'
```

### Branch Dessincronizada

Reconcilie primeiro a branch remota e use force-push somente se uma recuperação
do Space exigir isso explicitamente:
```bash
git fetch huggingface main
git push huggingface master:main
```

### HF Space Não Atualiza

1. Verificar se push foi bem-sucedido
2. Ir em https://huggingface.co/spaces/pi1704/epub-to-mp3
3. Clicar em "⋮" → "Factory reboot"
