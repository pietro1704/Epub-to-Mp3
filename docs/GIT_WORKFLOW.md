# Git Workflow - Branches e Deploy

## Status Atual

### Branches Configuradas

- **GitHub**: Usa `master` como branch principal
- **Hugging Face**: Usa `main` como branch padrão (configuração do HF)

### Configuração Automática

O repositório está configurado para **sincronizar automaticamente** `master` → `main` no Hugging Face.

Quando você faz:
```bash
git push huggingface
```

O Git automaticamente:
1. Envia `master` para `refs/heads/master` (branch master no HF)
2. Envia `master` para `refs/heads/main` (branch main no HF)

Ambas as branches ficam **idênticas** no HF.

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
- ✅ Enviar para HF (branches `master` e `main` sincronizadas)
- ✅ HF Space fará rebuild automático

### Método Alternativo (Manual)

Se preferir usar URLs diretas:

```bash
git push origin master
git push https://huggingface.co/spaces/pi1704/epub-to-mp3 master:main
git push https://huggingface.co/spaces/pi1704/epub-to-mp3 master:master
```

## Verificação

Para verificar se as branches estão sincronizadas:

```bash
git ls-remote huggingface
```

Você deve ver o mesmo commit hash para `main` e `master`:
```
76c893d... refs/heads/main
76c893d... refs/heads/master
```

## Por que Manter Ambas as Branches?

O Hugging Face usa `main` como branch padrão por convenção. Manter ambas sincronizadas garante:

1. ✅ HF Space sempre faz deploy da versão mais recente
2. ✅ Não precisa mudar configuração padrão do HF
3. ✅ GitHub continua usando `master` (sua convenção)
4. ✅ Zero conflitos entre plataformas

## Remover Branch Main (Opcional)

**⚠️ Não recomendado** - pode causar problemas no HF Space.

Se mesmo assim quiser remover `main` do HF:

1. Mudar branch padrão no HF:
   - Vá em https://huggingface.co/spaces/pi1704/epub-to-mp3/settings
   - Mude "Default branch" para `master`
   - Salve

2. Deletar branch `main`:
   ```bash
   git push huggingface --delete main
   ```

3. Atualizar configuração local:
   ```bash
   git config --local --unset-all remote.huggingface.push
   git config --local --add remote.huggingface.push '+refs/heads/master:refs/heads/master'
   ```

## Troubleshooting

### Erro: "remote.huggingface.push has multiple values"

Resetar configuração:
```bash
git config --local --unset-all remote.huggingface.push
git config --local --add remote.huggingface.push '+refs/heads/master:refs/heads/main'
git config --local --add remote.huggingface.push '+refs/heads/master:refs/heads/master'
```

### Branches Dessincronizadas

Forçar sincronização:
```bash
git push huggingface master:main --force
git push huggingface master:master --force
```

### HF Space Não Atualiza

1. Verificar se push foi bem-sucedido
2. Ir em https://huggingface.co/spaces/pi1704/epub-to-mp3
3. Clicar em "⋮" → "Factory reboot"
