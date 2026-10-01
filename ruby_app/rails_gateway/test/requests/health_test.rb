require "test_helper"

class HealthTest < ActionDispatch::IntegrationTest
  test "health delegates to Rust" do
    fake = Object.new
    def fake.health = { "status" => "healthy" }
    original = RustClient.method(:new)
    RustClient.define_singleton_method(:new) { fake }
    get "/health"
    assert_response :success
    assert_equal({ "status" => "healthy" }, JSON.parse(response.body))
  ensure
    RustClient.define_singleton_method(:new, original)
  end
end
