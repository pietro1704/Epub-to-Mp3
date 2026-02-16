from __future__ import annotations

import importlib

import pytest


@pytest.fixture(autouse=True)
def reset_env(monkeypatch):
    """Ensure guard env variables don't leak between tests."""
    for key in (
        "DISABLE_PIPER",
        "ENABLE_PIPER",
        "DISABLE_SPARK_TTS",
        "ENABLE_SPARK_TTS",
        "DISABLE_COQUI_TTS",
        "ENABLE_COQUI_TTS",
        "DISABLE_NUMPY_OPTIMIZATIONS",
    ):
        monkeypatch.delenv(key, raising=False)
    yield


def _mock_platform(monkeypatch, *, platform_name: str = "darwin", arch: str = "x86_64"):
    from python_app.src.tts import numpy_guard

    monkeypatch.setattr(numpy_guard.sys, "platform", platform_name)
    monkeypatch.setattr(numpy_guard.platform, "machine", lambda: arch)


def test_numpy_guard_disabled_on_intel_mac(monkeypatch):
    from python_app.src.tts import numpy_guard

    _mock_platform(monkeypatch)
    assert numpy_guard.is_numpy_safe_environment() is False


def test_numpy_guard_enabled_on_non_macos(monkeypatch):
    from python_app.src.tts import numpy_guard

    _mock_platform(monkeypatch, platform_name="linux", arch="x86_64")
    assert numpy_guard.is_numpy_safe_environment() is True


@pytest.mark.parametrize(
    ("module_name", "func_name", "env_enable", "env_disable"),
    [
        (
            "python_app.src.tts.piper_guard",
            "is_piper_supported_environment",
            "ENABLE_PIPER",
            "DISABLE_PIPER",
        ),
        (
            "python_app.src.tts.spark_guard",
            "is_spark_supported_environment",
            "ENABLE_SPARK_TTS",
            "DISABLE_SPARK_TTS",
        ),
        (
            "python_app.src.tts.coqui_guard",
            "is_coqui_supported_environment",
            "ENABLE_COQUI_TTS",
            "DISABLE_COQUI_TTS",
        ),
    ],
)
def test_guard_env_overrides(
    monkeypatch, module_name: str, func_name: str, env_enable: str, env_disable: str
):
    _mock_platform(monkeypatch)

    guard_module = importlib.import_module(module_name)

    # For piper_guard, also disable the binary check so only numpy guard decides
    if "piper_guard" in module_name:
        monkeypatch.setattr(guard_module, "_piper_binary_result", False)

    guard_func = getattr(guard_module, func_name)

    # Default on Intel macOS (no binary, no numpy safe): disabled
    assert guard_func() is False

    # Force enable even on unsafe platform
    monkeypatch.setenv(env_enable, "1")
    importlib.reload(guard_module)
    if "piper_guard" in module_name:
        monkeypatch.setattr(guard_module, "_piper_binary_result", False)
    assert getattr(guard_module, func_name)() is True

    # Force disable should win
    monkeypatch.setenv(env_disable, "1")
    importlib.reload(guard_module)
    if "piper_guard" in module_name:
        monkeypatch.setattr(guard_module, "_piper_binary_result", False)
    assert getattr(guard_module, func_name)() is False


def test_piper_guard_binary_check_allows_intel_mac(monkeypatch):
    """When piper binary works, Intel macOS should be allowed."""
    from python_app.src.tts import piper_guard

    _mock_platform(monkeypatch)
    # Simulate binary working
    monkeypatch.setattr(piper_guard, "_piper_binary_result", True)

    assert piper_guard.is_piper_supported_environment() is True


def test_piper_guard_binary_check_fails_falls_back_to_numpy(monkeypatch):
    """When piper binary doesn't work, fall back to numpy guard."""
    from python_app.src.tts import piper_guard

    _mock_platform(monkeypatch)
    # Simulate binary not working
    monkeypatch.setattr(piper_guard, "_piper_binary_result", False)

    # Intel macOS + no binary = False
    assert piper_guard.is_piper_supported_environment() is False


def test_piper_binary_works_caches_result(monkeypatch):
    """_piper_binary_works should cache its result."""
    from python_app.src.tts import piper_guard

    # Reset cache
    piper_guard._piper_binary_result = None

    call_count = 0
    original_which = piper_guard.shutil.which

    def mock_which(name):
        nonlocal call_count
        call_count += 1
        return None  # piper not found

    monkeypatch.setattr(piper_guard.shutil, "which", mock_which)

    assert piper_guard._piper_binary_works() is False
    assert piper_guard._piper_binary_works() is False
    # shutil.which should only be called once (cached)
    assert call_count == 1

    # Reset for other tests
    piper_guard._piper_binary_result = None
