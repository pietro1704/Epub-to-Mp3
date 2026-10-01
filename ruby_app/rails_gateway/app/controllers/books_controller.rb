class BooksController < ApplicationController
  def index = render json: Book.order(created_at: :desc)
  def show = render json: Book.find(params[:id])
  def create
    book = BookImporter.call(params.require(:file)); render json: book, status: :created
  rescue ActionController::ParameterMissing, ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
  def convert
    book = Book.find(params[:id]); job = ConvertBookJob.perform_later(book.id, params.permit(:engine, :voice, :language).to_h)
    render json: { bookId: book.id, jobId: job.job_id, status: "queued" }, status: :accepted
  rescue ActiveRecord::RecordNotFound
    render json: { error: "book not found" }, status: :not_found
  end
  def job
    book = Book.find(params[:id]); rust_job_id = book.job_id
    return render json: { bookId: book.id, status: book.status }, status: :accepted unless rust_job_id
    payload = RustClient.new.job(rust_job_id); sync_status(book, payload)
    render json: payload.merge("bookId" => book.id)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "book not found" }, status: :not_found
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end
  def output
    book = Book.find(params[:id]); job_id = book.job_id
    raise ActiveRecord::RecordNotFound unless job_id
    filename = params[:filename].to_s
    raise ArgumentError, "invalid output filename" unless filename.match?(/\A[a-zA-Z0-9._-]+\z/) && !filename.include?("..")
    bytes, content_type = RustClient.new.output(job_id, filename)
    send_data bytes, filename: filename, type: content_type || "application/octet-stream", disposition: "attachment"
  rescue ActiveRecord::RecordNotFound
    render json: { error: "book or output not found" }, status: :not_found
  rescue ArgumentError => e
    render json: { error: e.message }, status: :bad_request
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end
  private
  def sync_status(book, payload)
    state = payload["state"].to_s
    mapped = { "finished" => :ready, "completed" => :ready, "failed" => :failed, "cancelled" => :failed }.fetch(state, :converting)
    attrs = { status: mapped }; attrs[:error_message] = payload["error"] if mapped == :failed
    book.update!(attrs)
  end
end
