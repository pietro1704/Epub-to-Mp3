require "test_helper"

# Production serves precompiled assets through the static file server, which
# applies one cache policy to every public file; this covers that path.
class ImmutableAssetsTest < ActiveSupport::TestCase
  def respond(path, status: 200)
    static_files = ->(_env) { [ status, { "cache-control" => "no-cache" }, [] ] }
    ResponsePolicy::ImmutableAssets.new(static_files).call("PATH_INFO" => path)[1]["cache-control"]
  end

  test "digested assets are immutable and other public files keep revalidating" do
    assert_equal "public, max-age=31536000, immutable", respond("/assets/application-82d26f08.js")
    assert_equal "public, max-age=31536000, immutable", respond("/assets/application-82d26f08.js", status: 304)
    assert_equal "no-cache", respond("/sample.epub")
    assert_equal "no-cache", respond("/assets/missing.js", status: 404)
  end
end
