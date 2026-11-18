require "test_helper"

class WebManifestTest < ActionDispatch::IntegrationTest
  test "the installable workspace preserves the public manifest, icons and theme color" do
    get root_path
    assert_select 'meta[name="theme-color"][content="#1a1a1a"]'
    assert_select 'link[rel=manifest][href="/site.webmanifest"]'
    assert_select 'link[rel=apple-touch-icon][sizes="180x180"]'
    icons = css_select("link[rel=icon], link[rel=apple-touch-icon]").pluck("href")

    get "/site.webmanifest"
    assert_response :success
    manifest = JSON.parse(response.body)
    assert_equal [ "/", "/", "standalone", "EpubToMp3" ], manifest.values_at("id", "start_url", "display", "name")
    assert_equal %w[192x192 512x512], manifest.fetch("icons").pluck("sizes")
    icons += manifest.fetch("icons").pluck("src")
    assert_equal %w[/app-icon-192.png /app-icon-512.png /apple-touch-icon.png /favicon.ico /favicon.png], icons.sort
    icons.each do |path|
      get path
      assert_response :success
      signature = path.end_with?(".ico") ? "\x00\x00\x01\x00".b : "\x89PNG\r\n\x1a\n".b
      assert response.body.b.start_with?(signature), path
    end
  end
end
