require "test_helper"

class RepositoryContentTest < ActiveSupport::TestCase
  test "no voice model weights are shipped with the application" do
    weights = %w[public app].flat_map { |directory| Rails.root.glob("#{directory}/**/*.onnx") }

    assert_empty weights
  end

  test "the footer version matches the product version in the root Cargo.toml" do
    cargo = Rails.root.join("../../Cargo.toml").read
    product = cargo[/^\[workspace\.package\][^\[]*?^version = "([^"]+)"/m, 1]

    refute_nil product
    assert_equal product, Rails.root.join("VERSION").read.strip
  end
end
