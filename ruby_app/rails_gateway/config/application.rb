require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Rack middleware is built once at boot, so it is required rather than autoloaded.
require_relative "../lib/converter_runtime/file_server"
require_relative "../lib/response_policy/immutable_assets"

module RailsGateway
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks converter_runtime response_policy])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # The interface is server-rendered in two locales; "auto" resolves per request.
    config.i18n.available_locales = %i[en pt-BR]
    config.i18n.default_locale = :en

    # Shown in the footer. Releases override the checked-in value through APP_VERSION.
    config.x.application_version = ENV.fetch("APP_VERSION") { File.read(File.expand_path("../VERSION", __dir__)).strip }

    # The generated browser runtime is built outside Rails and never committed.
    config.x.converter_runtime.manifest_path = File.expand_path("runtime_manifest.json", __dir__)
    config.x.converter_runtime.root = File.expand_path("../public/runtime", __dir__)
  end
end
