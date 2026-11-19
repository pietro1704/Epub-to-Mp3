require "test_helper"

class RepositoryContentTest < ActiveSupport::TestCase
  test "no voice model weights are shipped with the application" do
    weights = %w[public app].flat_map { |directory| Rails.root.glob("#{directory}/**/*.onnx") }

    assert_empty weights
  end

  test "the footer version matches the React client while it exists" do
    react_manifest = Rails.root.join("../../web/package.json")
    skip "web/ is not part of this checkout" unless react_manifest.file?

    assert_equal JSON.parse(react_manifest.read).fetch("version"), Rails.root.join("VERSION").read.strip
  end
end
