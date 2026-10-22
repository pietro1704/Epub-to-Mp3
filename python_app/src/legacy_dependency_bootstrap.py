"""Legacy CLI dependency bootstrap; all process execution stays caller-injected."""

from __future__ import annotations

import os
from pathlib import Path


def install_requirements(
    loc, module_path, *, process_runner, exec_process, python_executable, argv,
) -> bool:
    python_root = Path(module_path).resolve().parents[1]
    project_root = python_root.parent
    candidate_paths = [
        Path("requirements.txt"),
        Path.cwd() / "requirements.txt",
        python_root / "requirements.txt",
    ]
    requirements_path = next((path for path in candidate_paths if path.exists()), None)

    if requirements_path is None:
        print(loc.t("requirements_not_found"))
        return False

    print(loc.t("installing_requirements"))
    result = process_runner(
        [python_executable, "-m", "pip", "install", "-r", str(requirements_path)],
        check=False,
        capture_output=True,
        text=True,
    )

    if result.returncode == 0:
        print(loc.t("requirements_success"))
        return True

    stderr = (result.stderr or "").lower()
    stdout = (result.stdout or "").lower()
    if "externally-managed-environment" in stderr or "externally-managed-environment" in stdout:
        if not os.getenv("EPUB2MP3_VENV_BOOTSTRAPPED"):
            venv_path = project_root / ".venv"
            venv_python = venv_path / "bin" / "python"
            try:
                if not venv_python.exists():
                    print("🔧 Criando ambiente virtual local (.venv)...")
                    process_runner(
                        [python_executable, "-m", "venv", str(venv_path)],
                        check=False,
                    )
                if venv_python.exists():
                    print("📦 Installing dependencies in .venv...")
                    process_runner(
                        [
                            str(venv_python),
                            "-m",
                            "pip",
                            "install",
                            "-r",
                            str(requirements_path),
                        ],
                        check=False,
                    )
                    os.environ["EPUB2MP3_VENV_BOOTSTRAPPED"] = "1"
                    exec_process(str(venv_python), [str(venv_python)] + argv)
            except Exception:
                pass

    print(loc.t("requirements_failure"))
    return False
