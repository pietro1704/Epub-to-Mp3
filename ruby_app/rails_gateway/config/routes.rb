Rails.application.routes.draw do
  get "/health", to: "health#show"
  get "/api/metadata", to: "health#metadata"
  resources :books, only: %i[index show create] do
    post :convert, on: :member
    get :job, on: :member
  end
end
