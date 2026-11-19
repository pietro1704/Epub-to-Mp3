require "test_helper"

class BooksTest < ActionDispatch::IntegrationTest
  def setup
    Book.delete_all
    @file = Rack::Test::UploadedFile.new(StringIO.new("epub"), "application/epub+zip", true, original_filename: "sample.epub")
    @configured_converter = ENV["RUST_CONVERTER_URL"]
    ENV["RUST_CONVERTER_URL"] = "http://127.0.0.1:1"
  end

  def teardown
    ENV["RUST_CONVERTER_URL"] = @configured_converter
  end

  test "imports and lists a book" do
    assert_difference("Book.count", 1) { post "/books", params: { file: @file } }
    assert_response :created; get "/books"; assert_response :success; assert_equal 1, JSON.parse(response.body).size
  end
  test "reports a queued book without a Rust job" do
    book = Book.create!(title: "Book", source_path: "/tmp/book.epub")
    get "/books/#{book.id}/job"; assert_response :accepted; assert_equal "imported", JSON.parse(response.body)["status"]
  end
  test "rejects unsafe output filenames" do
    book = Book.create!(title: "Book", source_path: "/tmp/book.epub", job_id: "job-1")
    get "/books/#{book.id}/outputs/..evil.mp3"; assert_response :not_found
  end
  test "accepts uploads from API clients that hold no authenticity token" do
    with_forgery_protection do
      assert_difference("Book.count", 1) { post "/books", params: { file: @file } }
      assert_response :created
    end
  end
  test "metadata delegates to converter-server" do
    fake = Object.new
    def fake.metadata = { "engines" => [ "edge" ] }
    original = RustClient.method(:new)
    RustClient.define_singleton_method(:new) { fake }
    get "/api/metadata"
    assert_response :success
    assert_equal({ "engines" => [ "edge" ] }, JSON.parse(response.body))
  ensure
    RustClient.define_singleton_method(:new, original)
  end
  test "the compatibility API is not mounted without a configured converter-server" do
    ENV.delete("RUST_CONVERTER_URL")
    book = Book.create!(title: "Book", source_path: "/tmp/book.epub")

    assert_no_difference("Book.count") { post "/books", params: { file: @file } }
    assert_response :not_found
    [ "/books", "/books/#{book.id}", "/books/#{book.id}/job", "/api/metadata" ].each do |path|
      get path
      assert_response :not_found, path
    end
  end
end
