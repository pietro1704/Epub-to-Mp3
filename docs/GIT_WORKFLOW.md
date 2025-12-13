# Git Workflow - Branches e Deploy

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

Forçar sincronização:
```bash
git push huggingface master:main --force
```

### HF Space Não Atualiza

1. Verificar se push foi bem-sucedido
2. Ir em https://huggingface.co/spaces/pi1704/epub-to-mp3
3. Clicar em "⋮" → "Factory reboot"
