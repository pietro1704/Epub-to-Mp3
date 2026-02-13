# -*- coding: utf-8 -*-
"""
Performance Configuration Module
Otimizações de hardware, threading e alocação de memória
"""

import multiprocessing
import os
import platform
import sys


def _skip_numpy_tuning() -> bool:
    """Return True when we should skip importing NumPy for perf tweaks."""
    override = str(os.getenv("DISABLE_NUMPY_OPTIMIZATIONS", "")).strip().lower()
    if override in {"1", "true", "yes", "on"}:
        return True
    if sys.platform != "darwin":
        return False
    # Apple's Accelerate on Intel macOS frequently crashes NumPy at import time.
    arch = platform.machine().lower()
    if arch in {"x86_64", "i386"}:
        return True
    return False


def configure_numpy_performance():
    """Configure NumPy para usar BLAS otimizado e threading."""
    if _skip_numpy_tuning():
        print("⚠️ [NumPy] Otimizações desativadas (macOS/Intel ou override)")
        return
    try:
        import numpy as np

        # **PERFORMANCE**: Usar todos os cores disponíveis
        cpu_count = multiprocessing.cpu_count()
        optimal_threads = max(1, cpu_count)

        # OpenBLAS threading
        os.environ["OPENBLAS_NUM_THREADS"] = str(optimal_threads)
        os.environ["MKL_NUM_THREADS"] = str(optimal_threads)
        os.environ["NUMEXPR_NUM_THREADS"] = str(optimal_threads)
        os.environ["OMP_NUM_THREADS"] = str(optimal_threads)

        print(f"🚀 [NumPy] BLAS threads: {optimal_threads}")

        # **PERFORMANCE**: Configurar alocador de memória otimizado
        if hasattr(np, "set_printoptions"):
            np.set_printoptions(threshold=1000)  # Reduzir output verboso

    except ImportError:
        pass


def configure_torch_performance():
    """Configure PyTorch para máxima performance em GPU/CPU."""
    try:
        disable_torch = str(os.getenv("DISABLE_TORCH", "")).strip().lower() in {
            "1",
            "true",
            "yes",
            "on",
        }
        if sys.platform == "darwin":
            disable_torch = True
        allow_no_shm = str(os.getenv("ALLOW_TORCH_NO_SHM", "")).strip().lower() in {
            "1",
            "true",
            "yes",
            "on",
        }
        if disable_torch:
            print("⚠️ [Torch] Desativado automaticamente (macOS ou DISABLE_TORCH=1)")
            return
        if not os.path.exists("/dev/shm") and not allow_no_shm:
            print("⚠️ [Torch] /dev/shm ausente - pulando init para evitar crash do OpenMP")
            print("   Defina ALLOW_TORCH_NO_SHM=1 para forçar.")
            return

        import torch

        # **GPU ACCELERATION**: Configurar CUDA
        if torch.cuda.is_available():
            # Número de GPUs disponíveis
            gpu_count = torch.cuda.device_count()
            print(f"🚀 [Torch] GPUs disponíveis: {gpu_count}")

            for i in range(gpu_count):
                gpu_name = torch.cuda.get_device_name(i)
                gpu_memory = torch.cuda.get_device_properties(i).total_memory / (1024**3)
                print(f"🚀 [GPU {i}] {gpu_name} - {gpu_memory:.1f} GB")

            # **PERFORMANCE**: Otimizações CUDA
            torch.backends.cudnn.enabled = True
            torch.backends.cudnn.benchmark = True  # Auto-tune kernels
            torch.backends.cudnn.deterministic = False  # Mais rápido mas não determinístico
            torch.backends.cuda.matmul.allow_tf32 = True  # TensorFloat-32 (3-8x mais rápido)
            torch.backends.cudnn.allow_tf32 = True

            # **MEMORY**: Configurar alocador de memória CUDA
            os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "max_split_size_mb:128"

            # **PERFORMANCE**: JIT compilation
            torch.jit.enable_onednn_fusion(True)

            print("✅ [Torch] CUDA otimizado: cuDNN benchmark + TF32 habilitado")
        else:
            print("⚠️ [Torch] CUDA não disponível - usando CPU")

            # **CPU OPTIMIZATION**: Configurar threads CPU
            cpu_count = multiprocessing.cpu_count()
            optimal_threads = max(1, cpu_count)

            try:
                torch.set_num_threads(optimal_threads)
                torch.set_num_interop_threads(optimal_threads)
                print(f"🚀 [Torch] CPU threads: {optimal_threads}")
            except RuntimeError:
                # Já foi inicializado, ignorar
                print("⚠️ [Torch] Threads já configurados anteriormente")

            # **CPU OPTIMIZATION**: MKL optimizations
            if hasattr(torch, "_C") and hasattr(torch._C, "_jit_set_profiling_mode"):
                torch._C._jit_set_profiling_mode(False)
                torch._C._jit_set_profiling_executor(False)

    except ImportError:
        pass


def configure_python_allocator():
    """Configure Python memory allocator para melhor performance."""
    # **MEMORY**: Usar pymalloc (alocador otimizado do Python)
    # Já habilitado por padrão em Python 3.x

    # **MEMORY**: Não limitar memória virtual; apenas ajustar file descriptors se possível
    try:
        import resource

        soft_fd, hard_fd = resource.getrlimit(resource.RLIMIT_NOFILE)
        target_fd = min(4096, hard_fd)
        if soft_fd < target_fd:
            resource.setrlimit(resource.RLIMIT_NOFILE, (target_fd, hard_fd))
            print(f"📂 [FD] Limite de file descriptors: {target_fd}")

    except (ImportError, ValueError, OSError) as e:
        print(f"⚠️ [Memory] Não foi possível configurar limites: {e}")


def configure_gc_optimization():
    """Configure garbage collector para otimizar performance."""
    import gc

    # **MEMORY**: Configurar thresholds do GC
    # (threshold0, threshold1, threshold2)
    # threshold0: número de alocações antes de gen0 collection
    # threshold1: número de gen0 collections antes de gen1 collection
    # threshold2: número de gen1 collections antes de gen2 collection

    # Valores otimizados para workloads com muita alocação temporária
    gc.set_threshold(1000, 15, 15)  # Mais agressivo em gen0, menos em gen1/2

    # **PERFORMANCE**: Desabilitar GC durante operações críticas
    # (será re-habilitado manualmente quando necessário)
    # gc.disable()  # Comentado - pode causar memory leaks se não for cuidadoso

    print(f"🗑️ [GC] Thresholds otimizados: {gc.get_threshold()}")


def configure_asyncio_performance():
    """Configure asyncio para máxima performance."""
    try:
        import asyncio

        # **PERFORMANCE**: Usar uvloop se disponível (2-4x mais rápido)
        try:
            import uvloop

            asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
            print("🚀 [AsyncIO] uvloop habilitado (2-4x mais rápido)")
        except ImportError:
            print("⚠️ [AsyncIO] uvloop não disponível - usando asyncio padrão")

    except ImportError:
        pass


def configure_threading_performance():
    """Configure threading limits para evitar overhead excessivo."""
    # **THREADING**: Limitar threads do sistema
    cpu_count = multiprocessing.cpu_count()

    # Configurar variáveis de ambiente para bibliotecas C
    optimal_threads = max(1, cpu_count)

    os.environ["OMP_NUM_THREADS"] = str(optimal_threads)
    os.environ["MKL_NUM_THREADS"] = str(optimal_threads)
    os.environ["NUMEXPR_NUM_THREADS"] = str(optimal_threads)

    print(f"🧵 [Threading] Threads globais: {optimal_threads}")


def apply_all_optimizations():
    """Aplica todas as otimizações de performance."""
    print("=" * 80)
    print("🚀 APLICANDO OTIMIZAÇÕES DE PERFORMANCE")
    print("=" * 80)

    configure_python_allocator()
    configure_gc_optimization()
    configure_threading_performance()
    configure_numpy_performance()
    configure_torch_performance()
    configure_asyncio_performance()

    print("=" * 80)
    print("✅ OTIMIZAÇÕES APLICADAS COM SUCESSO")
    print("=" * 80)


# Auto-aplicar otimizações quando módulo é importado
if __name__ != "__main__":
    # Apenas aplicar se não estiver sendo executado diretamente
    apply_all_optimizations()


if __name__ == "__main__":
    # Se executado diretamente, mostrar relatório de performance
    apply_all_optimizations()

    # Mostrar informações do sistema
    print("\n" + "=" * 80)
    print("📊 INFORMAÇÕES DO SISTEMA")
    print("=" * 80)

    import platform

    print(f"OS: {platform.system()} {platform.release()}")
    print(f"Python: {sys.version}")
    print(f"CPUs: {multiprocessing.cpu_count()}")

    try:
        import psutil

        memory = psutil.virtual_memory()
        print(f"Memória Total: {memory.total / (1024**3):.1f} GB")
        print(f"Memória Disponível: {memory.available / (1024**3):.1f} GB")
        print(f"Memória Usada: {memory.percent}%")
    except ImportError:
        print("psutil não disponível - instale para ver estatísticas de memória")

    try:
        import torch

        if torch.cuda.is_available():
            print("\n🎮 GPU INFO:")
            for i in range(torch.cuda.device_count()):
                print(f"  GPU {i}: {torch.cuda.get_device_name(i)}")
                props = torch.cuda.get_device_properties(i)
                print(f"    Memória: {props.total_memory / (1024**3):.1f} GB")
                print(f"    Compute Capability: {props.major}.{props.minor}")
    except ImportError:
        pass

    print("=" * 80)
