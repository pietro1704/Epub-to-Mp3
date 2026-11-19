require "test_helper"

class ResponseHeadersTest < ActionDispatch::IntegrationTest
  IMMUTABLE = "public, max-age=31536000, immutable".freeze

  test "serves the WebAssembly module of the runtime tree as application/wasm" do
    get runtime_url_for("wasm/converter_wasm_bg.wasm")

    assert_response :success
    assert_equal "application/wasm", response.media_type
    assert_equal IMMUTABLE, response.headers["Cache-Control"]
    assert_predicate response.body.bytesize, :positive?
  end

  test "serves .js and .mjs files of the runtime tree with a JavaScript type" do
    [ "wasm/converter_wasm.js", runtime_files.find { |path| path.end_with?(".mjs") } ].each do |path|
      get runtime_url_for(path)

      assert_response :success, path
      assert_equal "text/javascript", response.media_type, path
      assert_equal IMMUTABLE, response.headers["Cache-Control"], path
      assert_equal "nosniff", response.headers["X-Content-Type-Options"], path
    end
  end

  test "serves the runtime tree only under its current id and only its own files" do
    get "/runtime/#{'0' * 64}/wasm/converter_wasm.js"
    assert_response :not_found

    get runtime_url_for("wasm/absent.js")
    assert_response :not_found

    get runtime_url_for("../../../config/routes.rb")
    assert_response :not_found

    post runtime_url_for("wasm/converter_wasm.js")
    assert_response :not_found
  end

  test "marks digested assets immutable" do
    get "/"
    stylesheet = css_select("link[rel=stylesheet]").first["href"]
    module_path = JSON.parse(css_select("script[type=importmap]").first.text).dig("imports", "application")

    [ stylesheet, module_path ].each do |path|
      get path

      assert_response :success, path
      assert_equal IMMUTABLE, response.headers["Cache-Control"], path
    end
  end

  test "does not mark un-versioned public files immutable" do
    get "/robots.txt"

    assert_response :success
    assert_equal "no-cache", response.headers["Cache-Control"]
  end

  test "the document is revalidated on every visit" do
    get "/"

    assert_equal "text/html", response.media_type
    assert_equal "no-cache", response.headers["Cache-Control"]
  end

  test "stays out of cross-origin isolation" do
    get "/"

    assert_nil response.headers["Cross-Origin-Opener-Policy"]
    assert_nil response.headers["Cross-Origin-Embedder-Policy"]
  end

  test "enforces the policy including only the catalog download origins" do
    get "/"

    assert_nil response.headers["Content-Security-Policy-Report-Only"]
    policy = directives(response.headers["Content-Security-Policy"])
    assert_equal [ "'self'" ], policy.fetch("default-src")
    nonce = "'nonce-#{css_select('meta[name=csp-nonce]').first['content']}'"
    assert_equal [ "'self'", "'wasm-unsafe-eval'", nonce ], policy.fetch("script-src")
    assert_equal [ "'self'", nonce ], policy.fetch("style-src")
    assert_equal [ "'self'", "blob:" ], policy.fetch("worker-src")
    assert_equal [ "'self'", "blob:" ], policy.fetch("media-src")
    assert_equal [ "'self'", "data:", "blob:" ], policy.fetch("img-src")
    assert_equal [ "'self'", "blob:", "https://huggingface.co", "https://us.aws.cdn.hf.co" ], policy.fetch("connect-src")
    assert_equal [ "'self'", "https://huggingface.co" ], policy.fetch("frame-ancestors")
  end

  test "lets only the application itself and Hugging Face embed the document" do
    get "/"

    assert_equal [ "'self'", "https://huggingface.co" ], directives(response.headers["Content-Security-Policy"]).fetch("frame-ancestors")
    assert_nil response.headers["X-Frame-Options"]
  end

  test "gives the inline import map the nonce the policy admits" do
    get "/"

    nonce = css_select("meta[name=csp-nonce]").first["content"]
    assert_predicate nonce, :present?
    assert_equal nonce, css_select("script[type=importmap]").first["nonce"]
    assert_equal nonce, css_select("script[type=module]").first["nonce"]
  end

  private

  def runtime_files = JSON.parse(File.read(Rails.configuration.x.converter_runtime.manifest_path)).fetch("files").keys

  def runtime_url_for(relative_path) = "#{converter_runtime.base_path}#{relative_path}"

  def directives(header)
    header.to_s.split(";").map(&:split).reject(&:empty?).to_h { |name, *sources| [ name, sources ] }
  end
end
