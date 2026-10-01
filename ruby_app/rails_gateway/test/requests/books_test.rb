require "test_helper"
class BooksTest < ActionDispatch::IntegrationTest
  def setup
    Book.delete_all
    @file = Rack::Test::UploadedFile.new(StringIO.new("epub"), "application/epub+zip", true, original_filename: "sample.epub")
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
    get "/books/#{book.id}/outputs/..secret.mp3"; assert_response :bad_request
  end
end
