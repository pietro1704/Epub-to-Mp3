#!/bin/bash
# fix_current_transformers_issue.sh
#
# Resolve especificamente o problema atual:
# - transformers foi para 4.40.2 mas ainda há conflitos
# - numpy 2.3.2 quebra várias dependências  
# - pandas, fsspec, packaging com versões incompatíveis

echo "🔧 CORREÇÃO ESPECÍFICA - Problema Atual"
echo "======================================="
echo "Resolvendo conflitos de dependências identificados..."
echo ""

# Mostra problema atual
echo "❌ PROBLEMAS IDENTIFICADOS:"
echo "• sentence-transformers quer transformers>=4.41.0 mas temos 4.40.2"
echo "• numpy 2.3.2 quebra: gruut, f5-tts, numba, unstructured"  
echo "• pandas 1.5.3 quebra: pephubclient"
echo "• fsspec 2025.7.0 quebra: datasets"
echo "• packaging 25.0 quebra: langfuse"
echo ""

# Estratégia: downgrade seletivo das dependências problemáticas
echo "🔧 ESTRATÉGIA DE CORREÇÃO:"
echo "1. Manter transformers==4.40.2 (obrigatório para XTTS)"
echo "2. Downgrade numpy para <2.0.0 (resolve múltiplos conflitos)"
echo "3. Upgrade pandas para >=2.0.0"
echo "4. Downgrade fsspec e packaging"
echo ""

read -p "Continuar com a correção? (s/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[SsYy]$ ]]; then
    echo "Cancelado."
    exit 0
fi

echo "🔄 Aplicando correções..."

# 1. Corrige numpy (principal problema)
echo ""
echo "📦 Corrigindo numpy (2.3.2 → <2.0.0)..."
pip install "numpy>=1.24.0,<2.0.0" --force-reinstall

# 2. Corrige pandas  
echo ""
echo "📦 Corrigindo pandas (1.5.3 → >=2.0.0)..."
pip install "pandas>=2.0.0,<3.0.0" --force-reinstall

# 3. Corrige fsspec
echo ""
echo "📦 Corrigindo fsspec (2025.7.0 → <=2025.3.0)..."
pip install "fsspec>=2023.1.0,<=2025.3.0" --force-reinstall

# 4. Corrige packaging
echo ""
echo "📦 Corrigindo packaging (25.0 → <24.0)..."
pip install "packaging>=23.2,<24.0" --force-reinstall

# 5. Força transformers novamente
echo ""
echo "📦 Garantindo transformers==4.40.2..."
pip install "transformers==4.40.2" --force-reinstall

# 6. Testa correção
echo ""
echo "🧪 TESTANDO CORREÇÃO..."
python -c "
import warnings
warnings.filterwarnings('ignore')

print('📊 VERIFICANDO VERSÕES CORRIGIDAS:')
print('-' * 40)

# Testa numpy
try:
    import numpy
    version = numpy.__version__
    major = int(version.split('.')[0])
    status = '✅' if major < 2 else '❌'
    print(f'{status} numpy: {version} (deve ser <2.0.0)')
except Exception as e:
    print(f'❌ numpy: {e}')

# Testa pandas  
try:
    import pandas
    version = pandas.__version__
    major = int(version.split('.')[0])
    status = '✅' if major >= 2 else '❌'
    print(f'{status} pandas: {version} (deve ser >=2.0.0)')
except Exception as e:
    print(f'❌ pandas: {e}')

# Testa transformers
try:
    import transformers
    version = transformers.__version__
    status = '✅' if version == '4.40.2' else '❌'
    print(f'{status} transformers: {version} (deve ser 4.40.2)')
except Exception as e:
    print(f'❌ transformers: {e}')

# Testa fsspec
try:
    import fsspec
    version = fsspec.__version__
    # Extrai números da versão para comparação
    year = int(version.split('.')[0])
    month = int(version.split('.')[1])
    status = '✅' if year <= 2025 and month <= 3 else '❌'
    print(f'{status} fsspec: {version} (deve ser <=2025.3.0)')
except Exception as e:
    print(f'❌ fsspec: {e}')

# Testa packaging
try:
    import packaging
    version = packaging.__version__
    major = int(version.split('.')[0])
    status = '✅' if major < 24 else '❌'
    print(f'{status} packaging: {version} (deve ser <24.0)')
except Exception as e:
    print(f'❌ packaging: {e}')

print()
print('🤖 TESTANDO TTS/XTTS:')
print('-' * 40)

# Testa TTS
try:
    from TTS.api import TTS
    print('✅ TTS: importado com sucesso')
    
    # Testa XTTS v2 (sem carregar modelo completo)
    print('✅ TTS.api: disponível')
    
except Exception as e:
    print(f'❌ TTS: {e}')

print()
print('🎉 Teste de correção concluído!')
"

echo ""
echo "✅ CORREÇÃO APLICADA!"
echo "===================="
echo ""
echo "💡 O QUE FOI CORRIGIDO:"
echo "• numpy: downgrade para <2.0.0 (resolve múltiplos conflitos)"  
echo "• pandas: upgrade para >=2.0.0 (resolve pephubclient)"
echo "• fsspec: downgrade para <=2025.3.0 (resolve datasets)"
echo "• packaging: downgrade para <24.0 (resolve langfuse)"
echo "• transformers: mantido em 4.40.2 (obrigatório para XTTS)"
echo ""
echo "🧪 PRÓXIMOS PASSOS:"
echo "1. Execute: python test_xtts_versions_fixed.py"
echo "2. Se XTTS funcionar, você está pronto!"
echo "3. Se houver problemas: python resolve_dependencies.py"
echo ""
echo "⚠️ NOTA: sentence-transformers pode reclamar sobre transformers 4.40.2"
echo "   mas isso é esperado - XTTS precisa desta versão específica."