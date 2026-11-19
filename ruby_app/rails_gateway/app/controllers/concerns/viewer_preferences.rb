# Locale and theme negotiation shared by rendering and the preferences form.
# The cookie values are the ones the React client keeps in localStorage.
module ViewerPreferences
  extend ActiveSupport::Concern

  AUTOMATIC = "auto".freeze
  LOCALES = { "pt" => :"pt-BR", "en" => :en }.freeze
  THEMES = %w[light dark].freeze
  CHOICES = { locale: [ AUTOMATIC, *LOCALES.keys ], theme: [ AUTOMATIC, *THEMES ] }.freeze
  DOCUMENT_LANGUAGES = { "pt-BR": "pt-BR", en: "en-US" }.freeze

  included do
    helper_method :locale_mode, :theme_mode, :document_language
  end

  private

  def locale_mode = LOCALES.key?(cookies[:locale]) ? cookies[:locale] : AUTOMATIC

  def theme_mode = THEMES.include?(cookies[:theme]) ? cookies[:theme] : AUTOMATIC

  def viewer_locale = LOCALES.fetch(cookies[:locale]) { accepted_locale }

  def document_language = DOCUMENT_LANGUAGES.fetch(I18n.locale)

  # Server-side equivalent of the React resolveLocale(navigator.language):
  # the most preferred language decides, Portuguese or else English.
  def accepted_locale
    preferred = accepted_languages.each_with_index.max_by { |(_, quality), position| [ quality, -position ] }&.first&.first
    preferred.to_s.downcase.start_with?("pt") ? :"pt-BR" : :en
  end

  def accepted_languages
    request.headers["Accept-Language"].to_s.split(",").filter_map do |entry|
      tag, *parameters = entry.strip.split(";").map(&:strip)
      weight = parameters.find { |parameter| parameter.start_with?("q=") }
      quality = weight ? Float(weight.delete_prefix("q="), exception: false) : 1.0
      [ tag, quality ] if tag.present? && tag != "*" && quality&.positive?
    end
  end
end
