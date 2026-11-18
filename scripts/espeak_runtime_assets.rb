# frozen_string_literal: true

# Locates the eSpeak NG phonemizer data produced by the espeak-rs-sys build
# script. Cargo lays out build-script output as build/<package>-<hash> in older
# releases and build/<package>/<hash> in newer ones; accept both.
module EspeakRuntimeAssets
  REQUIRED_ENTRIES = %w[phontab phondata phonindex pt_dict].freeze
  PACKAGE_DIRECTORIES = 'espeak-rs-sys{-*,/*}'

  def self.find(root, target_directories)
    candidates = target_directories.flat_map do |directory|
      Dir.glob(File.join(root, directory, 'build', PACKAGE_DIRECTORIES, 'out', '{share,build}', 'espeak-ng-data', 'phontab'))
    end
    candidates.map { |path| File.dirname(path) }.sort.find do |directory|
      REQUIRED_ENTRIES.all? { |entry| File.file?(File.join(directory, entry)) }
    end
  end
end
