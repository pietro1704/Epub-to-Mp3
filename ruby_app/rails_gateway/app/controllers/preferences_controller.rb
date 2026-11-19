class PreferencesController < ApplicationController
  PREFERENCE_LIFETIME = 1.year

  # Stores the chosen locale and theme so the next response renders them on
  # the first byte. "auto" clears the cookie and negotiation applies again.
  def update
    chosen = CHOICES.filter_map { |name, allowed| [ name, params[name] ] if allowed.include?(params[name]) }
    return head :unprocessable_content if chosen.empty?

    chosen.each { |name, value| store_preference(name, value) }
    redirect_back_or_to root_path, status: :see_other
  end

  private

  def store_preference(name, value)
    return cookies.delete(name) if value == AUTOMATIC

    cookies[name] = { value: value, expires: PREFERENCE_LIFETIME, httponly: true }
  end
end
