# -*- coding: utf-8 -*-
"""
Performance Configuration Module
Hardware, threading and memory allocation tuning.
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
    """Configure NumPy to use optimized BLAS and threading."""
    if _skip_numpy_tuning():
        print("⚠️ [NumPy] Optimizations disabled (macOS/Intel or override)")
        return
    try:
        import numpy as np

        # **PERFORMANCE**: Use all available cores
        cpu_count = multiprocessing.cpu_count()
        optimal_threads = max(1, cpu_count)

        # OpenBLAS threading
        os.environ["OPENBLAS_NUM_THREADS"] = str(optimal_threads)
        os.environ["MKL_NUM_THREADS"] = str(optimal_threads)
        os.environ["NUMEXPR_NUM_THREADS"] = str(optimal_threads)
        os.environ["OMP_NUM_THREADS"] = str(optimal_threads)

        print(f"🚀 [NumPy] BLAS threads: {optimal_threads}")

        # **PERFORMANCE**: Configure optimized memory allocator
        if hasattr(np, "set_printoptions"):
            np.set_printoptions(threshold=1000)  # Reduce verbose output

    except ImportError:
        pass


def configure_torch_performance():
    """Configure PyTorch for maximum GPU/CPU performance."""
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
            print("⚠️ [Torch] Disabled automatically (macOS or DISABLE_TORCH=1)")
            return
        if not os.path.exists("/dev/shm") and not allow_no_shm:
            print("⚠️ [Torch] /dev/shm missing — skipping init to avoid OpenMP crash")
            print("   Set ALLOW_TORCH_NO_SHM=1 to force.")
            return

        import torch

        # **GPU ACCELERATION**: Configure CUDA
        if torch.cuda.is_available():
            # Number of available GPUs
            gpu_count = torch.cuda.device_count()
            print(f"🚀 [Torch] Available GPUs: {gpu_count}")

            for i in range(gpu_count):
                gpu_name = torch.cuda.get_device_name(i)
                gpu_memory = torch.cuda.get_device_properties(i).total_memory / (1024**3)
                print(f"🚀 [GPU {i}] {gpu_name} - {gpu_memory:.1f} GB")

            # **PERFORMANCE**: CUDA optimizations
            torch.backends.cudnn.enabled = True
            torch.backends.cudnn.benchmark = True  # Auto-tune kernels
            torch.backends.cudnn.deterministic = False  # Faster but non-deterministic
            torch.backends.cuda.matmul.allow_tf32 = True  # TensorFloat-32 (3-8× faster)
            torch.backends.cudnn.allow_tf32 = True

            # **MEMORY**: Configure CUDA memory allocator
            os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "max_split_size_mb:128"

            # **PERFORMANCE**: JIT compilation
            torch.jit.enable_onednn_fusion(True)

            print("✅ [Torch] CUDA optimized: cuDNN benchmark + TF32 enabled")
        else:
            print("⚠️ [Torch] CUDA not available — using CPU")

            # **CPU OPTIMIZATION**: Configure CPU threads
            cpu_count = multiprocessing.cpu_count()
            optimal_threads = max(1, cpu_count)

            try:
                torch.set_num_threads(optimal_threads)
                torch.set_num_interop_threads(optimal_threads)
                print(f"🚀 [Torch] CPU threads: {optimal_threads}")
            except RuntimeError:
                # Already initialized, skip
                print("⚠️ [Torch] Threads already configured")

            # **CPU OPTIMIZATION**: MKL optimizations
            if hasattr(torch, "_C") and hasattr(torch._C, "_jit_set_profiling_mode"):
                torch._C._jit_set_profiling_mode(False)
                torch._C._jit_set_profiling_executor(False)

    except ImportError:
        pass


def configure_python_allocator():
    """Configure Python memory allocator for better performance."""
    # **MEMORY**: Use pymalloc (Python's optimized allocator)
    # Already enabled by default in Python 3.x

    # **MEMORY**: Do not limit virtual memory; only adjust file descriptors if possible
    try:
        import resource

        soft_fd, hard_fd = resource.getrlimit(resource.RLIMIT_NOFILE)
        target_fd = min(4096, hard_fd)
        if soft_fd < target_fd:
            resource.setrlimit(resource.RLIMIT_NOFILE, (target_fd, hard_fd))
            print(f"📂 [FD] File descriptor limit: {target_fd}")

    except (ImportError, ValueError, OSError) as e:
        print(f"⚠️ [Memory] Could not configure limits: {e}")


def configure_gc_optimization():
    """Configure garbage collector for optimized performance."""
    import gc

    # **MEMORY**: Configure GC thresholds
    # (threshold0, threshold1, threshold2)
    # threshold0: number of allocations before gen0 collection
    # threshold1: number of gen0 collections before gen1 collection
    # threshold2: number of gen1 collections before gen2 collection

    # Tuned for workloads with heavy temporary allocation
    gc.set_threshold(1000, 15, 15)  # More aggressive in gen0, less in gen1/2

    # **PERFORMANCE**: Disable GC during critical operations
    # (will be re-enabled manually when needed)
    # gc.disable()  # Commented out — can cause memory leaks if not careful

    print(f"🗑️ [GC] Thresholds configured: {gc.get_threshold()}")


def configure_asyncio_performance():
    """Configure asyncio for maximum performance."""
    try:
        import asyncio

        # **PERFORMANCE**: Use uvloop if available (2-4× faster)
        try:
            import uvloop

            asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
            print("🚀 [AsyncIO] uvloop enabled (2-4× faster)")
        except ImportError:
            print("⚠️ [AsyncIO] uvloop not available — using standard asyncio")

    except ImportError:
        pass


def configure_threading_performance():
    """Configure threading limits to avoid excessive overhead."""
    # **THREADING**: Limit system threads
    cpu_count = multiprocessing.cpu_count()

    # Configure environment variables for C libraries
    optimal_threads = max(1, cpu_count)

    os.environ["OMP_NUM_THREADS"] = str(optimal_threads)
    os.environ["MKL_NUM_THREADS"] = str(optimal_threads)
    os.environ["NUMEXPR_NUM_THREADS"] = str(optimal_threads)

    print(f"🧵 [Threading] Global threads: {optimal_threads}")


def apply_all_optimizations():
    """Apply all performance optimizations."""
    print("=" * 80)
    print("🚀 APPLYING PERFORMANCE OPTIMIZATIONS")
    print("=" * 80)

    configure_python_allocator()
    configure_gc_optimization()
    configure_threading_performance()
    configure_numpy_performance()
    configure_torch_performance()
    configure_asyncio_performance()

    print("=" * 80)
    print("✅ OPTIMIZATIONS APPLIED SUCCESSFULLY")
    print("=" * 80)


# Auto-apply optimizations when module is imported
if __name__ != "__main__":
    # Only apply if not running directly
    apply_all_optimizations()


if __name__ == "__main__":
    # If run directly, show performance report
    apply_all_optimizations()

    # Show system information
    print("\n" + "=" * 80)
    print("📊 SYSTEM INFORMATION")
    print("=" * 80)

    import platform

    print(f"OS: {platform.system()} {platform.release()}")
    print(f"Python: {sys.version}")
    print(f"CPUs: {multiprocessing.cpu_count()}")

    try:
        import psutil

        memory = psutil.virtual_memory()
        print(f"Total Memory: {memory.total / (1024**3):.1f} GB")
        print(f"Available Memory: {memory.available / (1024**3):.1f} GB")
        print(f"Memory Used: {memory.percent}%")
    except ImportError:
        print("psutil not available — install it to see memory statistics")

    try:
        import torch

        if torch.cuda.is_available():
            print("\n🎮 GPU INFO:")
            for i in range(torch.cuda.device_count()):
                print(f"  GPU {i}: {torch.cuda.get_device_name(i)}")
                props = torch.cuda.get_device_properties(i)
                print(f"    Memory: {props.total_memory / (1024**3):.1f} GB")
                print(f"    Compute Capability: {props.major}.{props.minor}")
    except ImportError:
        pass

    print("=" * 80)
