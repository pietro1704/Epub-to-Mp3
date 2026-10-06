class ConvertBookJob < ApplicationJob
  queue_as :default
  def perform(book_id, options = {})
    book = Book.find(book_id)
    book.update!(status: :converting, error_message: nil)
    client = RustClient.new
    upload = client.upload_local(book.source_path)
    result = client.convert(upload_id: upload.fetch("uploadId"), **options.symbolize_keys)
    book.update!(status: :converting, job_id: result.fetch("jobId"))
    result
  rescue StandardError => e
    book&.update(status: :failed, error_message: e.message)
    raise
  end
end
