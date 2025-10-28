# Sistema de Paths Centralizados

## Visão Geral

Implementado um sistema centralizado de gerenciamento de paths que **sempre** usa a raiz do projeto para cache e output, independentemente de onde os comandos Python são executados.

## Arquivos Modificados

### 1. **Novo arquivo: `python_app/src/paths.py`**

Módulo centralizado que:
- Detecta automaticamente a raiz do projeto procurando por marcadores (`.git`, `pytest.ini`, etc.)
- Define `PROJECT_ROOT`, `CACHE_DIR` e `OUTPUT_DIR` sempre apontando para a raiz
- Fornece helpers `get_cache_path()` e `get_output_path()` para facilitar o uso

**Exemplo de uso:**
```python
from src.paths import CACHE_DIR, OUTPUT_DIR, get_cache_path

# Diretórios sempre na raiz do projeto
cache_file = CACHE_DIR / "meu_arquivo.json"
output_file = OUTPUT_DIR / "audio.mp3"

# Ou usando os helpers
cache_file = get_cache_path("subdir", "arquivo.json")
```

### 2. **`python_app/src/config.py`**

Mudanças:
- Importa `CACHE_DIR` e `OUTPUT_DIR` de `paths.py`
- `ConversionConfig.output_dir` agora é `Path` (antes era `str`)
- `ConversionConfig.cache_dir` agora usa `CACHE_DIR` como padrão
- Valores customizados ainda são respeitados se fornecidos explicitamente

### 3. **`python_app/src/cache_manager.py`**

Mudanças:
- Importa `CACHE_DIR` de `paths.py` em vez de usar `resolve_cache_root()`
- Sempre usa `CACHE_DIR` da raiz do projeto, a menos que seja explicitamente fornecido

### 4. **`python_app/src/utils.py`**

Mudanças:
- `resolve_cache_root()` agora é **DEPRECATED** e simplesmente retorna `CACHE_DIR`
- Mantido apenas para compatibilidade com código legado
- Documentação atualizada indicando para usar `from .paths import CACHE_DIR` diretamente

### 5. **`python_app/server.py`**

Mudanças:
- Importa `OUTPUT_DIR` de `paths.py`
- Prioriza variável de ambiente `OUTPUT_DIR` (para cloud deployments)
- Fallback para `/tmp/output` em HuggingFace Spaces
- Caso contrário, usa `OUTPUT_DIR` da raiz do projeto

## Comportamento

### Antes
```bash
# Executando de dentro de python_app/
cd /path/to/Epub-to-Mp3/python_app
python main.py ebook.epub
# Cache e output eram salvos em python_app/.cache e python_app/output
```

### Agora
```bash
# Executando de dentro de python_app/
cd /path/to/Epub-to-Mp3/python_app
python main.py ebook.epub
# Cache e output são SEMPRE salvos em /path/to/Epub-to-Mp3/.cache e /path/to/Epub-to-Mp3/output

# Executando da raiz do projeto
cd /path/to/Epub-to-Mp3
python python_app/main.py ebook.epub
# Mesmo resultado - sempre na raiz!
```

## Estrutura de Diretórios

```
Epub-to-Mp3/                    ← PROJECT_ROOT
├── .cache/                     ← CACHE_DIR (sempre aqui)
│   ├── livro1/
│   ├── livro2/
│   └── checkpoint_*.json
├── output/                     ← OUTPUT_DIR (sempre aqui)
│   ├── 001_Chapter1.mp3
│   └── 002_Chapter2.mp3
├── python_app/
│   ├── src/
│   │   ├── paths.py           ← Novo módulo
│   │   ├── config.py          ← Atualizado
│   │   ├── cache_manager.py   ← Atualizado
│   │   └── utils.py           ← Atualizado
│   ├── main.py
│   └── server.py              ← Atualizado
└── PATHS_CENTRALIZADOS.md     ← Este arquivo
```

## Testes de Validação

```bash
# Teste 1: Verificar paths da raiz
cd /path/to/Epub-to-Mp3/python_app
python -c "from src.paths import PROJECT_ROOT, CACHE_DIR, OUTPUT_DIR; \
    print(f'Root: {PROJECT_ROOT}'); \
    print(f'Cache: {CACHE_DIR}'); \
    print(f'Output: {OUTPUT_DIR}')"

# Teste 2: Verificar de dentro de src/
cd /path/to/Epub-to-Mp3/python_app/src
python -c "from paths import CACHE_DIR, OUTPUT_DIR; \
    print(f'Cache: {CACHE_DIR}'); \
    print(f'Output: {OUTPUT_DIR}')"

# Teste 3: Verificar integração com config
cd /path/to/Epub-to-Mp3/python_app
python -c "from src.config import AppConfig; \
    config = AppConfig().create_conversion_config('edge'); \
    print(f'Config Output: {config.output_dir}'); \
    print(f'Config Cache: {config.cache_dir}')"
```

Todos os testes devem mostrar paths apontando para `/path/to/Epub-to-Mp3/.cache` e `/path/to/Epub-to-Mp3/output`.

## Compatibilidade

- **Variáveis de ambiente**: `OUTPUT_DIR` e `EPUB_TO_MP3_CACHE_DIR` ainda são respeitadas para cloud deployments
- **Código legado**: `resolve_cache_root()` continua funcionando (retorna `CACHE_DIR`)
- **Customização**: Paths customizados ainda podem ser fornecidos explicitamente via argumentos

## Benefícios

✅ Cache e output sempre na raiz do projeto
✅ Não importa de onde você executa o comando Python
✅ Mais fácil encontrar e gerenciar arquivos gerados
✅ Consistente entre diferentes modos de execução
✅ Compatível com código existente
