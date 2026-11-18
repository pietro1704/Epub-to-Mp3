require "test_helper"

class HealthTest < ActionDispatch::IntegrationTest
  LOCAL_HEALTH = { "status" => "healthy", "contract_version" => "1", "backend" => "rails" }.freeze

  test "health answers locally on both paths without converter-server" do
    original = RustClient.method(:new)
    RustClient.define_singleton_method(:new) { |*| raise "health must not reach converter-server" }

    %w[/api/health /health].each do |path|
      get path

      assert_response :success, path
      assert_equal "application/json", response.media_type, path
      assert_equal LOCAL_HEALTH, JSON.parse(response.body), path
    end
  ensure
    RustClient.define_singleton_method(:new, original)
  end

  test "process liveness is available" do
    get "/up"

    assert_response :success
  end
end
