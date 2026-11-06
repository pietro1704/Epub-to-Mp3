# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative 'simulator_test_backend'

class SimulatorTestBackendTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @products = File.join(@directory, 'Products')
    @app = File.join(@products, 'Debug-iphonesimulator', 'EpubToMp3.app')
    FileUtils.mkdir_p(@app)
    @run = File.join(@products, 'EpubToMp3.xctestrun')
    File.write(@run, 'immutable-test-input')
    @options = { device: 'C2C7AC8A-9857-4305-A699-8C5D6645A47C', app: @app,
                 directory: @directory, test_run: @run,
                 test_selector: 'EpubToMp3UITests/ReaderModesUITests/testPaginated' }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_rejects_suite_wildcard_multiple_methods_and_foreign_products
    ['EpubToMp3UITests', 'EpubToMp3UITests/ReaderModesUITests', '-only-testing:Other',
     'EpubToMp3UITests/ReaderModesUITests/testOne,testTwo'].each do |selection|
      assert_raises(SimulatorResources::Refusal) { SimulatorTestBackend.new(**@options.merge(test_selector: selection)) }
    end
    foreign = File.join(@directory, 'other.xctestrun')
    File.write(foreign, 'foreign')
    assert_raises(SimulatorResources::Refusal) { SimulatorTestBackend.new(**@options.merge(test_run: foreign)) }
  end

  def test_changed_test_run_is_refused_before_launch
    backend = SimulatorTestBackend.new(**@options)
    File.write(@run, 'changed')
    assert_raises(SimulatorResources::Refusal) { backend.prepare(:test) }
  end

  def test_manifest_requires_exact_bounded_regressions_and_detects_mutation
    manifest = File.join(@directory, 'selection.json')
    selectors = SimulatorTestBackend::REGRESSION_METHODS
    options = @options.reject { |key, _| key == :test_selector }.merge(test_manifest: manifest)
    [[], selectors.take(10), selectors + [selectors.first], selectors.take(10) + [selectors.first],
     selectors.take(10) + ['EpubToMp3Tests/Other/*']].each do |invalid|
      File.write(manifest, JSON.generate(invalid))
      assert_raises(SimulatorResources::Refusal) { SimulatorTestBackend.new(**options) }
    end
    File.write(manifest, JSON.generate(selectors))
    assert_raises(SimulatorResources::Refusal) { SimulatorTestBackend.new(**options, test_selector: @options[:test_selector]) }
    backend = SimulatorTestBackend.new(**options)
    File.write(manifest, JSON.generate(selectors.reverse))
    assert_raises(SimulatorResources::Refusal) { backend.prepare(:test) }
  end

  def test_manifest_emits_only_the_eleven_explicit_methods
    manifest = File.join(@directory, 'selection.json')
    File.write(manifest, JSON.generate(SimulatorTestBackend::REGRESSION_METHODS))
    backend = SimulatorTestBackend.new(**@options.reject { |key, _| key == :test_selector }, test_manifest: manifest)
    received = nil
    backend.define_singleton_method(:spawn_test) { |*argv, **| received = argv; 12345 }
    backend.start(:test)
    actual = received.grep(/\A-only-testing:/).map { |item| item.delete_prefix('-only-testing:') }
    assert_equal SimulatorTestBackend::REGRESSION_METHODS, actual
    assert_equal 11, actual.length
    assert_equal 'test-without-building', received.last
  ensure
    backend&.instance_variable_get(:@log)&.close
  end

  def test_conversion_preset_rejects_partial_mixed_and_duplicate_selections
    manifest = File.join(@directory, 'conversion.json')
    selectors = SimulatorTestBackend::CONVERSION_METHODS
    options = @options.reject { |key, _| key == :test_selector }.merge(test_manifest: manifest)
    [selectors.take(1), selectors + [selectors.first], [selectors.first, selectors.first],
     [selectors.first, SimulatorTestBackend::REGRESSION_METHODS.first]].each do |invalid|
      File.write(manifest, JSON.generate(invalid))
      assert_raises(SimulatorResources::Refusal) { SimulatorTestBackend.new(**options) }
    end
    File.write(manifest, JSON.generate(selectors))
    backend = SimulatorTestBackend.new(**options)
    assert backend.test_session?
    assert_equal selectors, backend.instance_variable_get(:@test_selectors)
  end

  def test_seed_preserves_existing_different_file_and_rejects_symlink
    seed = File.join(@directory, 'source.epub')
    File.write(seed, 'verified-source')
    backend = SimulatorTestBackend.new(**@options, seed_book: seed)
    container = File.join(@directory, 'container')
    FileUtils.mkdir_p(container)
    backend.stage_seed(container)
    destination = File.join(container, 'Documents', 'EpubToMp3DevelopmentSeed.epub')
    assert_equal 'verified-source', File.read(destination)
    backend.stage_seed(container)
    File.write(destination, 'user-file')
    assert_raises(SimulatorResources::Refusal) { backend.stage_seed(container) }
    assert_equal 'user-file', File.read(destination)
    File.delete(destination)
    File.symlink(seed, destination)
    assert_raises(SimulatorResources::Refusal) { backend.stage_seed(container) }
    assert_equal 'verified-source', File.read(seed)
  end

  def test_only_existing_serial_selected_test_is_launched_in_owned_group
    backend = SimulatorTestBackend.new(**@options)
    received = nil
    backend.define_singleton_method(:spawn_test) { |*argv, **flags| received = [argv, flags]; 12345 }
    backend.start(:test)
    argv, flags = received
    assert_equal 'test-without-building', argv.last
    assert_equal 1, argv.count { |value| value.to_s.start_with?('-only-testing:') }
    assert_includes argv, "-only-testing:#{@options[:test_selector]}"
    assert_includes argv, "platform=iOS Simulator,id=#{@options[:device]}"
    assert_equal 'NO', argv[argv.index('-parallel-testing-enabled') + 1]
    assert_equal '1', argv[argv.index('-maximum-concurrent-test-simulator-destinations') + 1]
    assert flags[:pgroup]
    refute_includes argv, 'build'
    refute_includes argv, 'test'
  ensure
    backend&.instance_variable_get(:@log)&.close
  end
end
