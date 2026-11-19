class ApplicationController < ActionController::Base
  include ViewerPreferences

  around_action :use_viewer_locale
  before_action :revalidate_document

  private

  def use_viewer_locale(&action)
    I18n.with_locale(viewer_locale, &action)
  end

  # HTML carries per-viewer language, theme and the current runtime id.
  def revalidate_document
    expires_now
  end
end
