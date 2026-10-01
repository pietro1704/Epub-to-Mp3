# frozen_string_literal: true

require "minitest/autorun"
require "webrick"
require_relative "../rust_client"

class RustClientTest < Minitest::Test
  def setup
    @server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", AccessLog: [], Logger: WEBrick::Log.new(File::NULL))
    @port = @server.config[:Port]
    @server.mount_proc "/health" do |_req, res|
      res["Content-Type"] = "application/json"
      res.body = '{"status":"ok"}'
    end
    @server.mount_proc "/api/metadata" do |_req, res|
      res["Content-Type"] = "application/json"
      res.body = '{"status":"ok","engine":"edge"}'
    end
    @thread = Thread.new { @server.start }
    sleep 0.05
    @client = EpubToMp3::RustClient.new(base_url: "http://127.0.0.1:#{@port}")
  end

  def teardown
    @server.shutdown
    @thread.join
  end

  def test_health_delegates_to_rust
    assert_equal "ok", @client.health.fetch("status")
  end

  def test_metadata_delegates_to_rust
    assert_equal "edge", @client.metadata.fetch("engine")
  end
end
