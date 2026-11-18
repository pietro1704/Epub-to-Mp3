class HealthController < ActionController::API
  LOCAL_HEALTH = { status: "healthy", contract_version: "1", backend: "rails" }.freeze

  # Answers locally: the interface does not depend on converter-server.
  def show
    render json: LOCAL_HEALTH
  end

  def metadata
    render json: RustClient.new.metadata
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end
end
