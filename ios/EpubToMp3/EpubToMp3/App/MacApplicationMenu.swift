#if os(macOS)
import AppKit

@MainActor
enum MacApplicationMenu {
    static func make(target: EpubToMp3App? = nil) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: L10n.string("app.name"))
        let about = NSMenuItem(
            title: L10n.string("menu.about"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApplication.shared
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.string("nav.settings") + "…",
                                  action: #selector(EpubToMp3App.showSettings(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(
            title: L10n.string("menu.quitApp", L10n.string("app.name")),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApplication.shared
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenu = NSMenu(title: L10n.string("menu.file"))
        let importBook = NSMenuItem(
            title: L10n.string("menu.importBook"),
            action: #selector(EpubToMp3App.importBooks(_:)),
            keyEquivalent: "o"
        )
        importBook.target = target
        fileMenu.addItem(importBook)
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            NSMenuItem(
                title: L10n.string("common.close"),
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"
            )
        )
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenu = NSMenu(title: L10n.string("menu.edit"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenu = NSMenu(title: L10n.string("menu.view"))
        let toggleSidebar = NSMenuItem(
            title: L10n.string("nav.toggleSidebar"),
            action: #selector(EpubToMp3App.toggleNavigationSidebar(_:)),
            keyEquivalent: "s"
        )
        toggleSidebar.keyEquivalentModifierMask = [.command, .control]
        toggleSidebar.target = target
        viewMenu.addItem(toggleSidebar)
        let searchLibrary = NSMenuItem(
            title: L10n.string("menu.searchLibrary"),
            action: #selector(EpubToMp3App.focusLibrarySearch(_:)),
            keyEquivalent: "f"
        )
        searchLibrary.target = target
        viewMenu.addItem(searchLibrary)
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenu = NSMenu(title: L10n.string("menu.window"))
        windowMenu.addItem(
            NSMenuItem(
                title: L10n.string("menu.minimize"),
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
        )
        windowMenu.addItem(NSMenuItem(title: L10n.string("menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApplication.shared.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: L10n.string("menu.help"))
        let aboutHelp = NSMenuItem(
            title: L10n.string("menu.about"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutHelp.target = NSApplication.shared
        helpMenu.addItem(aboutHelp)
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        return mainMenu
    }

}
#endif
