Rails.application.routes.draw do
  get "/health", to: "health#show"
  get "/api/metadata", to: "health#metadata"
end
