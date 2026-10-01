# frozen_string_literal: true

require "json"
require "webrick"
require_relative "rust_client"

module EpubToMp3
  class Server
    def initialize(client: RustClient.new)
      @client = client
    end

    def app
      server = WEBrick::HTTPServer.new(Port: Integer(ENV.fetch("PORT", "9292")), BindAddress: ENV.fetch("BIND", "127.0.0.1"), AccessLog: [], Logger: WEBrick::Log.new(File::NULL))
      server.mount_proc "/health" do |_req, res|
        json(res, @client.health)
      rescue StandardError => e
        error(res, e)
      end
      server.mount_proc "/api/metadata" do |_req, res|
        json(res, @client.metadata)
      rescue StandardError => e
        error(res, e)
      end
      trap("INT") { server.shutdown }
      trap("TERM") { server.shutdown }
      server
    end

    private

    def json(response, value, status: 200)
      response.status = status
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(value)
    end

    def error(response, exception)
      json(response, { error: exception.message }, status: 502)
    end
  end
end

EpubToMp3::Server.new.app.start if $PROGRAM_NAME == __FILE__
