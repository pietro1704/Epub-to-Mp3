require "application_system_test_case"

class WorkspaceShellSystemTest < ApplicationSystemTestCase
  FABER_MODEL = "pt_BR-faber-medium".freeze

  test "the page entry initialises the Rust/WASM runtime and reads the TTS catalog" do
    visit root_path

    assert_runtime_ready
    assert_no_selector "[role=status]", text: "Loading..."
    catalog = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("runtime/converter_runtime")
        .then((runtime) => runtime.loadTtsCatalog())
        .then((catalog) => done({ version: catalog.version, models: catalog.models.map((model) => model.id) }))
        .catch((error) => done({ error: String(error) }))
    JS
    assert_equal 2, catalog.fetch("version"), catalog.inspect
    assert_includes catalog.fetch("models"), FABER_MODEL
    assert_equal false, page.evaluate_script("window.crossOriginIsolated")
    assert_empty page.evaluate_script("window.policyViolations")
  end

  test "an unavailable runtime replaces the loading state with the failure message" do
    chromium.network.intercept(pattern: "*converter_wasm_bg.wasm")
    chromium.on(:request) { |request| request.abort }

    visit root_path

    assert_selector "[data-converter-runtime-state-value='failed'][aria-busy='false'] [role=alert]",
      text: "Conversion server unavailable"
    assert_no_selector "[role=status]", text: "Loading..."
  end

  test "choosing a theme applies it without a reload and keeps it on the next visit" do
    emulate_color_scheme("light")
    visit root_path
    assert_selector "html.theme-light"
    light_background = page_background
    mark_document

    within("form[aria-label='Theme']") { click_button "Dark" }

    assert_selector "html.theme-dark"
    assert_selector "form[aria-label='Theme'] button.topbar__button--active", text: "Dark"
    assert_same_document
    refute_equal light_background, page_background
    assert_equal "dark", page.evaluate_script("localStorage.getItem('ebook-tts-theme')")

    visit root_path
    assert_selector "html.theme-dark"
    refute_equal light_background, page_background
  end

  test "automatic theme follows the operating system colour scheme" do
    emulate_color_scheme("dark")
    visit root_path
    assert_selector "html.theme-dark"
    dark_background = page_background

    emulate_color_scheme("light")

    assert_selector "html.theme-light"
    refute_equal dark_background, page_background
  end

  test "choosing English re-renders the visible strings and the document language" do
    prefer_language("pt-BR")
    visit root_path
    assert_selector "html[lang='pt-BR']"
    assert_button "Ajuda & Sistema"
    assert_runtime_ready
    mark_document

    within("form[aria-label='Idioma']") { click_button "Inglês" }

    assert_selector "html[lang='en-US']"
    assert_same_document
    assert_button "Help & System"
    assert_selector "[role=tab]", text: "1. Prepare conversion"
    assert_selector "form[aria-label='Language'] button.topbar__button--active", text: "English"
    assert_equal "en", page.evaluate_script("localStorage.getItem('ebook-tts-locale')")
    assert_runtime_ready
  end

  test "choices stored by the React client are honoured on the first visit" do
    visit root_path
    assert_selector "html[lang='en-US']"
    page.execute_script(<<~JS)
      localStorage.setItem("ebook-tts-locale", "pt")
      localStorage.setItem("ebook-tts-theme", "dark")
      sessionStorage.clear()
    JS

    visit root_path

    assert_selector "html.theme-dark[lang='pt-BR']"
    assert_selector "form[aria-label='Idioma'] button.topbar__button--active", text: "Português"
    assert_selector "form[aria-label='Tema'] button.topbar__button--active", text: "Escuro"
  end

  test "choosing automatic is not overridden by an older stored choice" do
    visit root_path
    within("form[aria-label='Theme']") { click_button "Dark" }
    assert_selector "html.theme-dark"
    emulate_color_scheme("light")

    within("form[aria-label='Theme']") { click_button "Auto" }
    assert_selector "form[aria-label='Theme'] button.topbar__button--active", text: "Auto"
    page.execute_script("sessionStorage.clear()")
    visit root_path

    assert_selector "html.theme-light"
    assert_selector "form[aria-label='Theme'] button.topbar__button--active", text: "Auto"
  end

  test "the help drawer opens from its toggle and closes with Escape, the overlay and its button" do
    visit root_path
    toggle = find_button("Help & System")
    assert_equal "false", toggle["aria-expanded"]
    assert_help_drawer_closed

    toggle.click
    assert_equal "true", toggle["aria-expanded"]
    assert_help_drawer_open
    within("#help-drawer") do
      assert_selector "h2", text: "Local conversion"
      assert_text "Compatible Piper models run locally after installation."
      assert_text "Ready to start"
    end

    find("body").send_keys(:escape)
    assert_help_drawer_closed
    assert_equal "false", toggle["aria-expanded"]

    toggle.click
    assert_help_drawer_open
    find(".help-drawer__overlay").click
    assert_help_drawer_closed

    toggle.click
    assert_help_drawer_open
    within("#help-drawer") { click_button "Close panel" }
    assert_help_drawer_closed
  end

  test "the help drawer takes keyboard focus while open and returns it to its toggle on every close" do
    visit root_path
    toggle = find_button("Help & System")

    toggle.click
    assert_help_drawer_open
    assert_help_drawer_close_button_focused
    page.send_keys(:tab)
    assert_help_drawer_close_button_focused
    page.send_keys([ :shift, :tab ])
    assert_help_drawer_close_button_focused

    page.send_keys(:escape)
    assert_help_drawer_closed
    assert_help_toggle_focused

    toggle.click
    assert_help_drawer_open
    find(".help-drawer__overlay").click
    assert_help_drawer_closed
    assert_help_toggle_focused

    toggle.click
    assert_help_drawer_open
    within("#help-drawer") { click_button "Close panel" }
    assert_help_drawer_closed
    assert_help_toggle_focused

    toggle.send_keys(:enter)
    assert_help_drawer_open
    assert_help_drawer_close_button_focused
    page.send_keys(:enter)
    assert_help_drawer_closed
    assert_help_toggle_focused
  end

  test "Escape with the help drawer closed leaves focus where it is" do
    visit root_path
    page.execute_script("document.querySelector(\"form[aria-label='Theme'] button[value='dark']\").focus()")
    assert_selector "form[aria-label='Theme'] button:focus", text: "Dark"
    page.send_keys(:escape)

    assert_selector "form[aria-label='Theme'] button:focus", text: "Dark"
  end

  test "a page restored by Turbo shows the help drawer closed with its toggle collapsed" do
    visit root_path
    mark_document
    find_button("Help & System").click
    assert_help_drawer_open

    # A visit to the current URL replaces the history entry; a distinct one is needed to go back.
    page.execute_script("Turbo.visit(#{root_path(visit: "next").to_json})")
    assert_current_path root_path(visit: "next")
    assert_help_drawer_closed
    page.go_back
    assert_current_path root_path

    assert_help_drawer_closed
    assert_equal "false", find_button("Help & System")["aria-expanded"]
    assert_same_document
  end

  test "the preferences form carries the authenticity token the server requires" do
    with_forgery_protection do
      visit root_path
      within("form[aria-label='Theme']") { click_button "Dark" }

      assert_selector "html.theme-dark"
      assert_selector "form[aria-label='Theme'] button.topbar__button--active", text: "Dark"
    end
  end

  private

  # Turbo Drive replaces the body; the JavaScript realm that will hold the
  # conversion session, the worker and the audio element must survive it.
  def mark_document = page.execute_script("window.documentMarker = 'kept'")

  def assert_same_document = assert_equal("kept", page.evaluate_script("window.documentMarker"))

  # Waits for the slide-in transition to finish: the close button moves during
  # it, so a click sent meanwhile can land beside the button.
  def assert_help_drawer_open
    assert_selector "#help-drawer.help-drawer--open[aria-hidden='false']:not([inert])"
    assert_selector ".help-drawer__overlay", visible: :visible
    assert_help_drawer_placement "settled on screen"
  end

  def assert_help_drawer_closed
    assert_selector "#help-drawer[aria-hidden='true'][inert]:not(.help-drawer--open)", visible: :all
    assert_no_selector ".help-drawer__overlay", visible: :visible
    assert_help_drawer_placement "off screen"
  end

  def assert_help_drawer_close_button_focused = assert_selector("#help-drawer .help-drawer__close:focus")

  def assert_help_toggle_focused = assert_selector(".help-toggle button[aria-controls='help-drawer']:focus")

  # The closed drawer is moved off the viewport rather than removed. Both
  # placements require its slide transition to have finished; the open drawer's
  # right edge meets the viewport's.
  def assert_help_drawer_placement(expected)
    page.document.synchronize do
      placement = page.evaluate_script(<<~JS)
        (() => {
          const drawer = document.getElementById("help-drawer")
          const sliding = drawer.getAnimations().some((animation) =>
            animation.transitionProperty === "right" && animation.playState === "running")
          if (sliding) return "moving"
          const rect = drawer.getBoundingClientRect()
          const viewportWidth = document.documentElement.clientWidth
          if (rect.left >= viewportWidth) return "off screen"
          return Math.abs(rect.right - viewportWidth) < 1 ? "settled on screen" : "partly on screen"
        })()
      JS
      raise Capybara::ExpectationNotMet, "help drawer is #{placement}, expected #{expected}" unless placement == expected
    end
  end

  def page_background = page.evaluate_script("getComputedStyle(document.documentElement).getPropertyValue('--bg-color').trim()")
end
