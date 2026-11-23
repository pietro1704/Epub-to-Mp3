# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# The Faber fixture is restored from the Actions cache but every consumer still
# verifies the pinned checksums, so a cache or provider fault cannot weaken tests.
class FaberTestModelActionTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  ACTION = './.github/actions/faber-test-model'
  ONNX = '858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7'
  CONFIG = '7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f'
  REVISION = 'c10ece1aade47bb51c153c893d14e5bf8e5b7117'

  def action
    YAML.load_file(File.join(ROOT, '.github/actions/faber-test-model/action.yml'))
  end

  def test_action_is_keyed_by_revision_and_checksum_and_saves_only_on_master
    steps = action.fetch('runs').fetch('steps')
    restore = steps.find { |step| step['id'] == 'restore' }
    save = steps.find { |step| step['uses'].to_s.start_with?('actions/cache/save@') }
    assert restore.fetch('uses').start_with?('actions/cache/restore@')
    [restore, save].each do |step|
      key = step.fetch('with').fetch('key')
      [REVISION, ONNX, '${{ runner.os }}'].each { |part| assert_includes key, part }
    end
    assert_includes save.fetch('if'), "github.ref == 'refs/heads/master'"
    assert_includes save.fetch('if'), "steps.restore.outputs.cache-hit != 'true'"
    assert_operator steps.index(restore), :<, steps.index { |step| step['run'] }
    assert_operator steps.index { |step| step['run'] }, :<, steps.index(save), 'Only verified files are cached'
  end

  def test_download_fallback_is_pinned_retried_and_always_verified
    script = action.fetch('runs').fetch('steps').find { |step| step['run'] }.fetch('run')
    assert_includes script, "revision=#{REVISION}"
    assert_includes script, "onnx_sha=#{ONNX}"
    assert_includes script, "config_sha=#{CONFIG}"
    assert_includes script, '--retry 8 --retry-delay 15 --retry-all-errors'
    assert_includes script, 'verified "$1" "$2" ||'
    assert_includes script, 'cp "$CACHE_DIR/$onnx"', 'Consumers get the verified bytes'
    refute_match(/\|\|\s*true/, script)
  end

  def test_every_consumer_uses_the_action_and_none_downloads_the_model_itself
    workflows = %w[faber-integration ci flutter-rust-faber].to_h do |name|
      [name, File.read(File.join(ROOT, ".github/workflows/#{name}.yml"))]
    end
    assert_equal 1, workflows.fetch('faber-integration').scan("uses: #{ACTION}").size
    assert_equal 1, workflows.fetch('ci').scan("uses: #{ACTION}").size
    assert_equal 2, workflows.fetch('flutter-rust-faber').scan("uses: #{ACTION}").size
    workflows.each_value { |text| refute_includes text, 'huggingface.co/rhasspy/piper-voices' }
  end
end
