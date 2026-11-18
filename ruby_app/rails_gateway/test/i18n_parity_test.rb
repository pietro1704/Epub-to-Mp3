require "test_helper"
require "open3"
require "yaml"

class I18nParityTest < ActiveSupport::TestCase
  test "both Rails locales expose the same labels and interpolation arguments" do
    assert_equal signatures(catalog("en")), signatures(catalog("pt-BR"))
  end

  test "every React label has a Rails counterpart or an explicit ADR exclusion" do
    output, status = Bundler.with_unbundled_env do
      Open3.capture2("node", Rails.root.join("test/support/react_locale_keys.mjs").to_s)
    end
    assert_predicate status, :success?
    original = JSON.parse(output)
    assert_equal original.fetch("en"), original.fetch("pt")
    exemptions = YAML.safe_load_file(Rails.root.join("test/support/react_locale_exclusions.yml"))
    assert exemptions.keys.all? { |row| /\AN-(?:0[1-9]|1[0-9]|2[0-5])\z/.match?(row) }
    excluded = exemptions.values.flatten
    assert_empty excluded - original.fetch("en"), "Retire waivers for removed source keys"
    %w[en pt-BR].each do |locale|
      labels = catalog(locale)
      missing = (original.fetch("en") - excluded).reject { |key| labels.dig(*key.split(".")) }
      assert_empty missing, "Missing React keys in #{locale}"
    end
  end

  private

  def catalog(locale)
    Rails.root.glob("config/locales/*.yml").each_with_object({}) do |path, labels|
      labels.deep_merge!(YAML.safe_load_file(path).fetch(locale, {}))
    end
  end

  def signatures(value, path = [])
    if value.is_a?(Hash)
      return value.each_with_object({}) { |(key, item), result| result.merge!(signatures(item, path + [ key ])) }
    end
    { path.join(".") => value.to_s.scan(/%?\{(\w+)\}/).flatten.uniq.sort }
  end
end
