class ConvertBookJob < ApplicationJob
  queue_as :default
  def perform(book_id, options = {})
    book = Book.find(book_id)
    book.update!(status: :converting, error_message: nil)
    result = RustClient.new.convert(input: book.source_path, **options.symbolize_keys)
    book.update!(status: :converting, job_id: result.fetch("jobId"))
    result
  rescue StandardError => e
    book&.update(status: :failed, error_message: e.message)
    raise
  end
end
