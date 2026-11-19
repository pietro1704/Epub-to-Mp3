Rails.application.routes.draw do
  # The whole interface is one document; conversion runs in the browser.
  root "workspace#show"
  patch "/preferences", to: "preferences#update", as: :preferences

  get "/up", to: "rails/health#show", as: :rails_health_check
  get "/api/health", to: "health#show"
  get "/health", to: "health#show"

  # Server-side compatibility API that delegates to converter-server. The
  # interface never calls it, so it answers only when that server is configured.
  constraints(->(_request) { ENV["RUST_CONVERTER_URL"].present? }) do
    get "/api/metadata", to: "health#metadata"
    resources :books, only: %i[index show create] do
      post :convert, on: :member
      get :job, on: :member
      get "outputs/:filename", action: :output, on: :member, as: :output
    end
  end
end
