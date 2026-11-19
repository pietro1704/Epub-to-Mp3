ENV["RAILS_ENV"] ||= "test"
require_relative "support/runtime_fixture"
RuntimeFixture.publish unless RuntimeFixture.built_runtime?

require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Two workers at most, on developer machines and in continuous integration.
    parallelize(workers: [ 2, Etc.nprocessors ].min)

    def converter_runtime = Rails.configuration.x.converter_runtime.tree

    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
  end
end
