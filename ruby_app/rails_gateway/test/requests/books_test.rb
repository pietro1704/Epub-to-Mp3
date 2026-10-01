require "test_helper"
class BooksTest < ActionDispatch::IntegrationTest
  def setup
    Book.delete_all
    @file = Rack::Test::UploadedFile.new(StringIO.new("epub"), "application/epub+zip", true, original_filename: "sample.epub")
  end
  test "imports and lists a book" do
    assert_difference("Book.count", 1) { post "/books", params: { file: @file } }
    assert_response :created
    get "/books"
    assert_response :success
    assert_equal 1, JSON.parse(response.body).size
  end
end
