class BooksController < ApplicationController
  def index
    render json: Book.order(created_at: :desc)
  end
  def show
    render json: Book.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "book not found" }, status: :not_found
  end
  def create
    book = BookImporter.call(params.require(:file))
    render json: book, status: :created
  rescue ActionController::ParameterMissing, ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
  def convert
    book = Book.find(params[:id])
    job = ConvertBookJob.perform_later(book.id, params.permit(:engine, :voice, :language).to_h)
    render json: { bookId: book.id, jobId: job.job_id, status: "queued" }, status: :accepted
  rescue ActiveRecord::RecordNotFound
    render json: { error: "book not found" }, status: :not_found
  end
  def job
    book = Book.find(params[:id])
    rust_job_id = book.job_id
    return render json: { bookId: book.id, status: book.status }, status: :accepted unless rust_job_id
    payload = RustClient.new.job(rust_job_id)
    render json: payload.merge("bookId" => book.id)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "book not found" }, status: :not_found
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end
end
