require "test_helper"

class WorkspaceShellTest < ActionDispatch::IntegrationTest
  SHELL_TEXT = {
    "pt-BR" => {
      language: "pt", document_language: "pt-BR", preferences: "Preferências de tema e idioma",
      theme: [ "Tema", %w[Auto Claro Escuro] ], locale: [ "Idioma", %w[Auto Português Inglês] ],
      tabs: [ "1. Preparar conversão", "2. Acompanhar andamento", "3. Ouvir e baixar" ],
      setup_panel: [ "Envie seu livro", "Faça o upload e escolha como o áudio deve soar." ],
      help_toggle: "Ajuda & Sistema", help_title: "Ajuda e monitoramento", help_close: "Fechar painel",
      local_runtime: "Conversão local", idle: "Pronto para começar", loading: "Carregando...",
      capability: "Modelos Piper compatíveis funcionam localmente após a instalação. Edge não está disponível neste navegador."
    },
    "en-US" => {
      language: "en", document_language: "en-US", preferences: "Theme and language preferences",
      theme: [ "Theme", %w[Auto Light Dark] ], locale: [ "Language", %w[Auto Portuguese English] ],
      tabs: [ "1. Prepare conversion", "2. Track progress", "3. Listen & download" ],
      setup_panel: [ "Upload your book", "Send the file and define how the audio should sound." ],
      help_toggle: "Help & System", help_title: "Help and monitoring", help_close: "Close panel",
      local_runtime: "Local conversion", idle: "Ready to start", loading: "Loading...",
      capability: "Compatible Piper models run locally after installation. Edge is unavailable in this browser."
    }
  }.freeze

  SHELL_TEXT.each_value do |text|
    test "renders the shell landmarks and version in #{text[:document_language]}" do
      get "/", headers: { "Accept-Language" => text[:language] }

      assert_response :success
      assert_select "html[lang='#{text[:document_language]}']"
      assert_select "main.content-shell", 1
      assert_select "footer.status-bar .status-bar__version", "v#{Rails.configuration.x.application_version}"
    end

    test "renders theme and locale controls as labelled groups in #{text[:document_language]}" do
      get "/", headers: { "Accept-Language" => text[:language] }

      assert_select ".topbar[aria-label='#{text[:preferences]}']" do
        { theme: text[:theme], locale: text[:locale] }.each do |preference, (label, choices)|
          assert_select "form[role=group][aria-label='#{label}'][action='/preferences']" do
            assert_select "input[name=_method][value=patch]", 1
            assert_select ".topbar__label", label
            assert_equal choices, css_select("button[type=submit][name=#{preference}]").map { |button| button.text.strip }
            assert_select "button.topbar__button--active[value=auto]", 1
          end
        end
      end
    end

    test "renders the three tabs with setup selected and the others gated in #{text[:document_language]}" do
      get "/", headers: { "Accept-Language" => text[:language] }

      assert_select "[role=tablist][aria-label='Conversion flow'] [role=tab]", 3
      assert_equal text[:tabs], css_select("[role=tab] .tabs__label").map(&:text)
      assert_select "#tab-setup[aria-selected=true][aria-controls=panel-setup]:not([disabled])", 1
      %w[progress downloads].each do |tab|
        assert_select "#tab-#{tab}[aria-selected=false][aria-disabled=true][disabled]", 1
        assert_select "#panel-#{tab}[role=tabpanel][aria-labelledby=tab-#{tab}][hidden]", 1
      end
      assert_select "#panel-setup[role=tabpanel]:not([hidden])" do
        assert_select ".panel__title", text[:setup_panel].first
        assert_select ".panel__description", text[:setup_panel].last
      end
    end

    test "renders the closed help drawer with local runtime text in #{text[:document_language]}" do
      get "/", headers: { "Accept-Language" => text[:language] }

      assert_select ".help-toggle button[aria-expanded=false][aria-controls=help-drawer]", text[:help_toggle]
      assert_select ".help-drawer__overlay[role=button][hidden][aria-label='#{text[:help_close]}']", 1
      assert_select "aside#help-drawer[aria-hidden=true]" do
        assert_select ".help-drawer__header strong", text[:help_title]
        assert_select "button.help-drawer__close[aria-label='#{text[:help_close]}']", 1
        assert_select "section[aria-label='#{text[:local_runtime]}']" do
          assert_select "h2", text[:local_runtime]
          assert_select "p", text[:capability]
          assert_select "p", text[:idle]
        end
      end
    end

    test "shows the runtime loading state in #{text[:document_language]}" do
      get "/", headers: { "Accept-Language" => text[:language] }

      assert_select "[aria-busy=true] [role=status]", text[:loading]
      assert_select "[aria-busy=true] [role=alert][hidden]", 1
    end
  end

  test "keeps the hero out of view while no book or job exists" do
    get "/"

    assert_select "header.hero[hidden] [role=progressbar][aria-valuenow='0']", 1
  end

  test "accepts tab deep links without leaving the single document" do
    %w[progress downloads].each do |tab|
      get "/", params: { tab: tab }

      assert_response :success
      assert_select "[role=tablist] [role=tab]", 3
    end
  end

  test "announces the runtime tree and loads page code through the import map" do
    get "/"

    assert_select "meta[name=converter-runtime-base][content='#{converter_runtime.base_path}']", 1
    import_map = JSON.parse(css_select("script[type=importmap]").first.text).fetch("imports")
    %w[application @hotwired/turbo-rails @hotwired/stimulus controllers/theme_controller
       controllers/help_drawer_controller runtime/converter_runtime].each do |specifier|
      get import_map.fetch(specifier)
      assert_response :success, specifier
      assert_includes response.media_type, "javascript", specifier
    end
  end
end
