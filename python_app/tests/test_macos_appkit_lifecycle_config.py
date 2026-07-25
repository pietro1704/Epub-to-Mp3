"""Regression checks for the native macOS AppKit lifecycle configuration."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_macos_target_declares_nsapplication_principal_class() -> None:
    project = (ROOT / "ios" / "EpubToMp3" / "project.yml").read_text(encoding="utf-8")
    app_delegate = (
        ROOT / "ios" / "EpubToMp3" / "EpubToMp3" / "App" / "EpubToMp3App.swift"
    ).read_text(encoding="utf-8")
    macos_main = (ROOT / "ios" / "EpubToMp3" / "EpubToMp3" / "App" / "main.swift").read_text(
        encoding="utf-8"
    )

    assert '"INFOPLIST_KEY_NSPrincipalClass[sdk=macosx*]": "NSApplication"' in project
    assert "\n@main\n" not in app_delegate
    assert "static func runApp()" in app_delegate
    assert "#if os(macOS)" in macos_main
    assert "EpubToMp3App.runApp()" in macos_main
    assert "UIApplicationMain(" in macos_main
    assert "NSStringFromClass(EpubToMp3App.self)" in macos_main
    assert "application.delegate = delegate" in app_delegate
    assert "delegate.configureMainWindowIfNeeded()" in app_delegate
    assert "application.finishLaunching()" in app_delegate
    assert "application.run()" in app_delegate
    assert "sidecar" not in app_delegate.lower()
    assert "guard window == nil else { return }" in app_delegate
    assert "NSScreen.main?.visibleFrame" in app_delegate
    assert "NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }" not in app_delegate
    assert "bootstrapEmbeddedRuntime" in app_delegate
    assert "application.mainMenu = makeMainMenu()" in app_delegate
    assert "#selector(NSApplication.terminate(_:))" in app_delegate
    assert "root.view.translatesAutoresizingMaskIntoConstraints = false" in app_delegate
    assert (
        "root.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)" in app_delegate
    )
    assert "root.configureWindowToolbar(window)" in app_delegate
    root = (
        ROOT / "ios" / "EpubToMp3" / "EpubToMp3" / "App" / "MacAppKitRootController.swift"
    ).read_text(encoding="utf-8")
    assert "action: #selector(toggleNavigationSidebar)" in root
    assert 'L10n.string("nav.toggleSidebar")' in root
    assert "NSTitlebarAccessoryViewController()" in root
    assert "accessory.layoutAttribute = .leading" in root
    assert "window.addTitlebarAccessoryViewController(accessory)" in root
    assert "guard !Self.isRunningUnderXCTest() else { return }" in app_delegate
