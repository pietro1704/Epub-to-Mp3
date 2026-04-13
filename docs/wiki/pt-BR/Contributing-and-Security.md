# Contribuição e Segurança

## Contribuindo

## Regras práticas

- use `mise` para tarefas e toolchain
- teste toda mudança
- mantenha código, logs e comentários em inglês
- preserve o espelhamento entre CLI e Web quando houver mudança de comportamento

## Tarefas comuns

```bash
mise run test
mise run test:unit
mise run test:web
mise run test:desktop
```

## Fluxo recomendado

1. altere o código
2. adicione ou atualize testes
3. valide localmente
4. abra PR
5. acompanhe CI e CodeQL

## Segurança

Consulte também:

- [SECURITY.md](/Users/pietropugliesi/Developer/Epub-to-Mp3/SECURITY.md)

Pontos principais:

- não abra issue pública para vulnerabilidade
- use GitHub Security Advisories
- inclua impacto, reprodução e versões afetadas

## Escopo de segurança

Em escopo:

- path traversal
- RCE via EPUB/PDF malicioso
- bypass de autenticação/autorização
- CVEs exploráveis em dependências

Fora de escopo:

- acesso local à máquina
- DoS por arquivo gigante já mitigado por limites de capítulo
- problemas em serviços terceirizados de TTS
