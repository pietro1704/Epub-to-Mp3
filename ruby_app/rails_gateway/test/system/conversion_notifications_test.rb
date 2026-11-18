require "application_system_test_case"

class ConversionNotificationsTest < ApplicationSystemTestCase
  setup do
    skip "requires the built conversion runtime" unless RuntimeFixture.built_runtime?
  end

  test "a failed job emits one browser notification and a resumed job can notify again" do
    chromium.evaluate_on_new_document(<<~JS)
      window.notifications = []
      window.Notification = class {
        static permission = "granted"
        constructor(title, { body }) { window.notifications.push({ title, body }) }
      }
    JS
    start_conversion(failNext: 1)
    assert_selector "#panel-progress [role=alert]", text: "Details:"
    notices = page.evaluate_script("window.notifications")
    assert_equal [ "Conversion failed" ], notices.pluck("title")
    assert_predicate notices.first.fetch("body"), :present?
    click_button "1. Prepare conversion"
    steer_fixture(failNext: 1)
    click_button "Resume now"
    assert_selector "#panel-progress [role=alert]", text: "Details:"
    assert_equal [ "Conversion failed" ] * 2, page.evaluate_script("window.notifications").pluck("title")
  end

  test "a Space without browser permission shows a cancellation toast that expires" do
    chromium.headers.set("Accept-Language" => "en-US", "X-Forwarded-Host" => "conversion-test.hf.space")
    chromium.evaluate_on_new_document('window.Notification = class { static permission = "denied" }')
    start_conversion(delayMs: 400)
    assert_selector "#tab-progress[aria-selected=true]"
    accept_confirm { click_button "Stop conversion" }
    assert_selector ".conversion-notifications [role=status]", text: "Conversion cancelled"
    assert_no_selector ".conversion-notifications [role=status]", wait: 8
  end

  test "a progress deep link waits for the tab and is consumed before the job finishes" do
    start_conversion(tab: "progress", delayMs: 300)
    assert_selector "#tab-progress[aria-selected=true]"
    assert_selector "#tab-downloads[aria-selected=true]", wait: 30
    downloads = find("#tab-downloads")
    downloads.send_keys(:left)
    assert_selector "#tab-progress:focus[aria-selected=true]"
    find("#tab-progress").send_keys(:home)
    assert_selector "#tab-setup:focus[aria-selected=true]"
    find("#tab-setup").send_keys(:left)
    assert_selector "#tab-downloads:focus[aria-selected=true]"
    assert_empty page.evaluate_async_script("navigator.serviceWorker.getRegistrations().then(registrations => arguments[0](registrations.map(r => r.scope)))")
  end

  test "the Portuguese workspace carries the selected language into progress and downloads" do
    prefer_language("pt-BR")
    visit root_path
    assert_runtime_ready
    assert_selector "html[lang=pt-BR]", visible: :all
    click_button "Usar livro de exemplo"
    assert_selector ".book-queue__item[data-status=ready]"
    click_button "Converter agora"
    assert_selector "#tab-downloads[aria-selected=true]", text: "3. Ouvir e baixar", wait: 30
    click_button "2. Acompanhar andamento"
    within(".chapter-progress") do
      assert_text "Progresso por capítulo"
      click_button "Mostrar todo texto"
      assert_button "Baixar texto completo"
      assert_selector "details[open] .segment p", minimum: 1
    end
    assert_empty page.evaluate_script("window.policyViolations")
  end

  private

  def start_conversion(tab: nil, **settings)
    visit root_path(tab: tab)
    assert_runtime_ready
    assert_selector "#tab-setup[aria-selected=true]"
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    steer_fixture(**settings)
    click_button "Convert now"
  end

  def steer_fixture(**settings)
    page.execute_script(<<~JS, settings.to_json)
      Object.assign(window.conversionFixture ??= { requests: [], delayMs: 0, failNext: 0 }, JSON.parse(arguments[0]))
    JS
  end
end
