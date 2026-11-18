require "test_helper"

# The conversion fixture synthesis is a test-environment seam only: the page
# names it in the test environment and never outside it, and the module is
# not on the asset paths of any other environment.
class ConversionFixtureSeamTest < ActionDispatch::IntegrationTest
  FIXTURE_META = 'meta[name="conversion-test-fixture"]'.freeze

  test "the test page names the fixture module, which is served as JavaScript" do
    get root_path

    fixture = css_select(FIXTURE_META).first
    assert fixture, "the test page must name the conversion fixture"
    get fixture["content"]
    assert_response :success
    assert_match %r{\A(text|application)/javascript}, response.media_type
    assert_includes response.body, "export const synthesis"
  end

  test "outside the test environment the page does not reference the fixture" do
    with_environment("production") { get root_path }

    assert_response :success
    assert_empty css_select(FIXTURE_META)
    assert_not_includes response.body, "conversion_fixture"
  end

  test "only the test environment adds the fixture directory to the asset paths" do
    fixture_directory = "test/javascript"
    environments = Rails.root.glob("config/environments/*.rb").to_h { |path| [ path.basename(".rb").to_s, path.read ] }

    assert_includes environments.fetch("test"), fixture_directory
    environments.except("test").each do |name, source|
      assert_not_includes source, fixture_directory, "#{name} must not serve test-only page modules"
    end
    assert_not_includes Rails.root.join("config/initializers/assets.rb").read, fixture_directory if Rails.root.join("config/initializers/assets.rb").exist?
  end

  private

  def with_environment(name)
    previous = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = previous
  end
end
