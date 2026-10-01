class HealthController < ActionController::API
  def show
    render json: RustClient.new.health
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  def metadata
    render json: RustClient.new.metadata
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end
end
