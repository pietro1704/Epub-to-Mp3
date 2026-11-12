# frozen_string_literal: true

require_relative 'simulator_backend'
require 'fileutils'

# Runs only an existing, explicitly selected XCTest artifact under the same
# watchdog. A completed command is not a parsed XCTest acceptance result.
class SimulatorTestBackend < SimulatorBackend
  REGRESSION_METHODS = {
    'NativePlaybackFeedbackTests' => %w[
      testBothMenusIncludeNormalSpeedAndMarkExactlyTheActiveRateIncludingLegacyValues
      testExpandedPanelStartsAtRootSafeAreaInBothOrientations
      testOutputRequiresAdvancingCurrentItemAndClearsForWaitingSeekReplacementAndStaleTicks
      testReaderHighlightPreservesAnnotationsAndOffsetAndRejectsAnotherChapterOrBook
      testRepeatedWordsUseTheirOwnUTF16Range
      testRepeatedSentencesAfterEmojiResolveInReadingOrder
      testSpeechHighlightsRequireOutputCallbacksAndRejectPausedOrObsoleteUtterances
      testListeningActivitySessionCannotCreateOrEndAnActivity
    ],
    'NativeTransportFeedbackTests' => %w[
      testFifteenSecondCommandsAndChapterBoundariesPreservePause
      testExpandedSliderCommitsArbitraryPositionAndLatestSeekWins
      testConfirmedOutputDisappearsImmediatelyOnPauseAndSeek
    ]
  }.flat_map { |type, methods| methods.map { |method| "EpubToMp3Tests/#{type}/#{method}" } }.freeze
  CONVERSION_METHODS = %w[
    EpubToMp3Tests/PdfEmbeddedConversionTests/testPDFKitDocumentOpensThroughBundledRustWithUnicodeTextAndMetadata
    EpubToMp3Tests/ConversionOptionsInteropTests/testOptInSystemProviderPublishesPlayableMP3ThroughRust
  ].freeze

  # Closed, task-scoped native control/geometry regression batch. The resource,
  # identity, deadline and cleanup admission rules are unchanged.
  APPLE_EXPERIENCE_METHODS = %w[
    EpubToMp3Tests/BackendSettingsRowsTests/testAbsentWarningDoesNotReserveAnEmptyLastRow
    EpubToMp3Tests/BackendSettingsRowsTests/testDisabledRemoteBackendHasOneVisibleURLCellEvenWithInvalidURL
    EpubToMp3Tests/PlatformSettingsCellTests/testReusingAnInformationCellReleasesItsPreviousSwitch
    EpubToMp3Tests/PlatformSettingsCellTests/testPlatformRowIsReadOnlyInformation
    EpubToMp3Tests/VoiceModelSettingsNavigationTests/testVoiceModelsPushTheirOwnDestinationAndReturnWithoutInlineExpansion
    EpubToMp3Tests/PointPresetScaleTests/testAnExistingValueRemainsReachableWithoutChangingStoredPreferences
    EpubToMp3Tests/PointPresetScaleTests/testIrregularFontScaleKeepsTheExistingNearestChoices
    EpubToMp3Tests/PointPresetSliderTests/testNativeSliderAndAccessibilityUseTheSamePresetValues
    EpubToMp3Tests/PointPresetSliderTests/testSettingsRowsUpdateWithoutReplacingTheSliderOrPresentingAnAlert
    EpubToMp3Tests/ReaderToolPreferenceTests/testRecentToolDefaultsAndPersistsAcrossRelaunch
    EpubToMp3Tests/ReaderToolBarTests/testExactlyTwoNativeItemsKeepIdentityAfterUsingAnotherTool
    EpubToMp3Tests/ReaderSavedHighlightsTests/testRemovingTheLastSavedHighlightRestoresOriginalBookBackground
    EpubToMp3Tests/ReaderSavedHighlightsTests/testRemovalDoesNotChangeAnotherHighlightOrTextAndRangesStayBounded
    EpubToMp3Tests/ReaderSavedHighlightsTests/testNativeWordSelectionCanTargetAPartialHighlightInsideTheWord
    EpubToMp3Tests/ReaderSavedHighlightsTests/testPlaybackOffsetUsesUnicodeScalarBoundariesInsteadOfUTF16Length
    EpubToMp3Tests/MiniPlayerDismissalTests/testDismissalSurvivesNavigationAndRelaunchUntilNewPlaybackForThatBook
    EpubToMp3Tests/MiniPlayerDismissalTests/testDismissalCannotReviveTheOldAudioBookAfterReturningFromAnotherReader
    EpubToMp3Tests/MiniPlayerDismissalTests/testShortCancelledAndUpwardDragsNeverDismiss
    EpubToMp3Tests/LibraryGridLayoutMetricsTests/testAccessibilityTextUsesOneFullWidthColumn
    EpubToMp3Tests/LibraryGridLayoutMetricsTests/testPhoneTileReservesSpaceForCoverAndMetadata
    EpubToMp3Tests/LibraryGridLayoutMetricsTests/testDefaultDensityFitsWithoutExceedingTheRequestedCount
    EpubToMp3Tests/LibraryGridLayoutMetricsTests/testUnavailableWidthUsesOneColumnWithoutInvalidArithmetic
    EpubToMp3Tests/LibraryGridLayoutMetricsTests/testRequestedColumnsReturnAfterNarrowingAndAccessibilityConstraints
    EpubToMp3Tests/LibraryGridLayoutMetricsTests/testColumnPreferenceSurvivesReopeningWithoutSavingTemporaryDensity
    EpubToMp3Tests/LibraryGridLayoutMetricsTests/testTileWidthGrowsInsteadOfAddingColumns
    EpubToMp3Tests/LibraryGridLayoutMetricsTests/testWideTilesUseBothColumnsWithoutUnusedSpace
    EpubToMp3Tests/LibraryGridLayoutMetricsTests/testTileWidthFillsUsableSpaceAcrossColumns
    EpubToMp3Tests/LibraryGridLayoutMetricsTests/testTileWidthNeverNegative
    EpubToMp3Tests/IOSLibraryCollectionLayoutTests/testActualLibraryCollectionHasTwoItemsPerRowAcrossResize
    EpubToMp3Tests/ReaderChromeOverlayTests/testChromeRoundTripsPreserveTheActualNativeReadingViewport
    EpubToMp3Tests/BookLanguageDecisionTests/testCorrectionsRemainScopedToContentIdentityAndManualChoicesWin
    EpubToMp3Tests/BookLanguageDecisionTests/testLegacyModelMismatchUsesTheSameNativeRecoveryContract
    EpubToMp3Tests/BookLanguageDecisionTests/testCompatibleSecondaryRecoveryKeepsPrimaryAndAutomaticLanguage
    EpubToMp3Tests/BookLanguageDecisionTests/testRenderedSelectionMapsToSourceScalarsAndRejectsAmbiguousText
    EpubToMp3Tests/LocalizationCoverageTests/testSupportedLocalesHaveEveryEnglishKeyAndMatchingFormatArguments
    EpubToMp3Tests/ReaderAccessibilityContractTests/testNativeReaderInstallsStableContentAndNavigationIdentifiers
    EpubToMp3Tests/ReaderListeningSessionTests/testConstructingSessionNeverOpensOrStartsPlayback
    EpubToMp3Tests/ReaderListeningSessionTests/testCancellationRejectsLateFileOpenBeforeItTouchesThePlayer
    EpubToMp3Tests/ReaderListeningSessionTests/testBookReplacementRejectsLateFileOpenBeforeItTouchesThePlayer
    EpubToMp3Tests/ReaderListeningSessionTests/testCurrentOpenFailureReportsWithoutInstallingAPlaybackSession
  ].freeze

  def initialize(test_run:, test_selector: nil, test_manifest: nil, seed_book: nil, **options)
    super(**options)
    @test_run = File.realpath(test_run)
    raise SimulatorResources::Refusal, 'Choose selector or manifest' unless [test_selector, test_manifest].compact.length == 1
    if test_manifest
      @test_manifest = File.realpath(test_manifest)
      @manifest_digest = Digest::SHA256.file(@test_manifest).hexdigest
      @test_selectors = JSON.parse(File.read(@test_manifest))
      unless @test_selectors.is_a?(Array) && [REGRESSION_METHODS, CONVERSION_METHODS, APPLE_EXPERIENCE_METHODS].any? { |allowed|
        @test_selectors.length == allowed.length && @test_selectors.uniq.sort == allowed.sort
      }
        raise SimulatorResources::Refusal, 'Manifest must select exactly an approved test preset'
      end
    else
      @test_selectors = [test_selector]
    end
    unless @test_selectors.all? { |selector| selector.is_a?(String) && selector.match?(%r{\AEpubToMp3(?:UI)?Tests/[A-Za-z0-9_]+/test[A-Za-z0-9_]+\z}) }
      raise SimulatorResources::Refusal, 'One explicit XCTest method required'
    end
    products = File.realpath(File.dirname(File.dirname(@app)))
    unless File.dirname(@test_run) == products && @test_run.end_with?('.xctestrun')
      raise SimulatorResources::Refusal, 'Test run must belong to the application products'
    end
    @test_digest = Digest::SHA256.file(@test_run).hexdigest
    if seed_book
      @seed_book = File.realpath(seed_book)
      raise SimulatorResources::Refusal, 'EPUB seed required' unless @seed_book.end_with?('.epub')
      @seed_digest = Digest::SHA256.file(@seed_book).hexdigest
    end
  end

  def test_session?; true; end

  def inspect_identity(**options)
    super.merge('test_run' => @test_run, 'test_run_sha256' => @test_digest, 'test_selectors' => @test_selectors,
      'manifest_sha256' => @manifest_digest)
  end

  def prepare(stage)
    super
    if stage == :test && Digest::SHA256.file(@test_run).hexdigest != @test_digest
      raise SimulatorResources::Refusal, 'Test run changed before execution'
    end
    if stage == :test && @test_manifest && Digest::SHA256.file(@test_manifest).hexdigest != @manifest_digest
      raise SimulatorResources::Refusal, 'Test manifest changed before execution'
    end
  end

  def start(stage)
    return super unless stage == :test
    raise SimulatorResources::Refusal, 'Previous command still active' if @pid
    @app_pid = nil # XCTest owns application relaunches during the test.
    @stage = stage
    @log = File.open(File.join(@directory, 'test.log'), 'wx', 0o600)
    @pid = spawn_test(@environment, '/usr/bin/xcrun', 'xcodebuild', '-quiet',
      '-xctestrun', @test_run, '-destination', "platform=iOS Simulator,id=#{@device}",
      '-jobs', '1', '-parallel-testing-enabled', 'NO',
      '-maximum-concurrent-test-simulator-destinations', '1',
      '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '60',
      '-maximum-test-execution-time-allowance', '120',
      *@test_selectors.map { |selector| "-only-testing:#{selector}" }, '-resultBundlePath', File.join(@directory, 'tests.xcresult'),
      'test-without-building', pgroup: true, out: @log, err: @log)
  end

  def spawn_test(*arguments, **options)
    Process.spawn(*arguments, **options)
  end

  def poll
    stage = @stage
    status = super
    if stage == :install && status == 0 && @seed_book
      Timeout.timeout(8) do
        raise SimulatorResources::Refusal, 'Seed source changed' unless Digest::SHA256.file(@seed_book).hexdigest == @seed_digest
        container = capture('/usr/bin/xcrun', 'simctl', 'get_app_container', @device, @bundle, 'data').strip
        stage_seed(container)
      end
    end
    status
  rescue Timeout::Error
    raise SimulatorResources::Refusal, 'Seed staging deadline exceeded'
  end

  def stage_seed(container)
    documents = File.join(File.realpath(container), 'Documents')
    raise SimulatorResources::Refusal, 'Symlinked documents' if File.symlink?(documents)
    Dir.mkdir(documents) unless File.exist?(documents)
    destination = File.join(documents, 'EpubToMp3DevelopmentSeed.epub')
    raise SimulatorResources::Refusal, 'Symlinked seed destination' if File.symlink?(destination)
    if File.exist?(destination)
      raise SimulatorResources::Refusal, 'Different seed already exists' unless Digest::SHA256.file(destination).hexdigest == @seed_digest
    else
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
        File.open(@seed_book, 'rb') { |input| IO.copy_stream(input, output) }
      end
      raise SimulatorResources::Refusal, 'Seed copy differs' unless Digest::SHA256.file(destination).hexdigest == @seed_digest
    end
  end
end
