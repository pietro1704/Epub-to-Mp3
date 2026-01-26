#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para visualizar configurações de auto-tuning.

Usage:
    python show_autotuning.py              # Mostra config atual
    python show_autotuning.py --measure    # Mede rede também
"""

import argparse
import asyncio

from python_app.src.auto_tuner import AutoTuner


async def main():
    parser = argparse.ArgumentParser(description="Visualizar configurações de auto-tuning")
    parser.add_argument(
        "--measure",
        action="store_true",
        help="Medir velocidade de rede (adiciona ~3s)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Aplicar configurações ao ambiente",
    )
    args = parser.parse_args()

    tuner = AutoTuner(verbose=True)

    # Auto-configure
    profile = await tuner.auto_configure(
        force=args.apply,
        measure_network=args.measure,
    )

    print("\n" + "=" * 70)
    print("💡 RECOMENDAÇÕES")
    print("=" * 70)

    if profile.name == "Conservative":
        print("🐌 Perfil conservador detectado.")
        print("   • Considere melhorar conexão de internet")
        print("   • Ou aumentar RAM disponível")
        print("   • Conversões serão mais lentas mas estáveis")
    elif profile.name == "Balanced":
        print("⚖️  Perfil balanceado detectado.")
        print("   • Bom equilíbrio entre velocidade e estabilidade")
        print("   • Para melhorar: upgrade de internet ou RAM")
    elif profile.name == "Performance":
        print("🚀 Perfil de performance detectado!")
        print("   • Boa configuração para conversões rápidas")
        print("   • Sistema otimizado")
    else:  # Maximum
        print("⚡ Perfil máximo detectado!")
        print("   • Configuração ideal para conversões ultra-rápidas")
        print("   • Aproveite ao máximo!")

    print("\n💾 Para desabilitar auto-tuning:")
    print("   export ENABLE_AUTO_TUNING=0")
    print("\n🔧 Para forçar um perfil específico, setehoje manualmente:")
    print("   export EDGE_MAX_CONCURRENCY=8")
    print("   export EDGE_CHUNK_CHARS=10000")
    print("=" * 70 + "\n")


if __name__ == "__main__":
    asyncio.run(main())
