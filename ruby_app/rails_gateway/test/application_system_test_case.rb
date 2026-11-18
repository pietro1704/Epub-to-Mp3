require "test_helper"
require "capybara/cuprite"

# A real headless Chromium driven over the DevTools protocol. BROWSER_PATH
# selects the binary when it is not at a standard location.
Capybara.register_driver(:headless_chromium) do |app|
  browser_options = ENV["CI"] ? { "no-sandbox" => nil } : {}
  Capybara::Cuprite::Driver.new(app, headless: true, window_size: [ 1280, 900 ], process_timeout: 30, timeout: 20,
    browser_options: browser_options)
end
Capybara.default_max_wait_time = 10
# Controls are found by their accessible name, including aria-label.
Capybara.enable_aria_label = true

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :headless_chromium

  RECORD_POLICY_VIOLATIONS = <<~JS.freeze
    window.policyViolations = []
    document.addEventListener("securitypolicyviolation", (event) => {
      window.policyViolations.push(`${event.effectiveDirective} ${event.blockedURI}`)
    })
  JS

  setup do
    # Capture violations of the enforced policy for the entire page lifetime.
    chromium.evaluate_on_new_document(RECORD_POLICY_VIOLATIONS)
    prefer_language("en-US")
  end

  # Automatic locale comes from Accept-Language, which defaults to the host's.
  def prefer_language(language)
    chromium.headers.set("Accept-Language" => language)
  end

  def chromium = page.driver.browser

  def emulate_color_scheme(scheme)
    chromium.page.command("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme } ])
  end

  def assert_runtime_ready
    assert_selector "[data-controller~='converter-runtime'][data-converter-runtime-state-value='ready'][aria-busy='false']"
  end
end
