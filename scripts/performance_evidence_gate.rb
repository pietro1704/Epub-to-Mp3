#!/usr/bin/env ruby
# frozen_string_literal: true

# Import source-backed observations without claiming an unmeasured release gate.

require "fileutils"
require "io/console"
require_relative "apple_latency_evidence"
require_relative "python_json"

module PerformanceEvidenceGate
  DESCRIPTION = "Import source-backed observations without claiming an unmeasured release gate."
  SCHEMA_VERSION = 2
  DEFAULT_CLIENTS = %w[apple web flutter].freeze
  DEFAULT_CORPORA = %w[epub selectable_text_pdf sideways_two_up_scanned_pdf].freeze
  DEFAULT_CACHE_STATES = %w[cold relaunch_warm].freeze
  POLICIES = %w[normal reading_priority playback_priority resource_constrained].freeze
  # These require executable collectors/output checks, not user-supplied flags.
  # Do not remove a requirement until its actual evidence adapter is implemented.
  PENDING_REQUIREMENTS = %w[
    automated_collection_lifecycle representative_corpus_verification streaming_backend_correlation
    conversion_output_integrity_cli conversion_output_integrity_server web_profile_collection
    flutter_profile_collection
  ].freeze
  CAPTURE_FIELDS = %w[
    client runner execution_environment revision run_id source_sha256 journeys corpus cache_state resource_policy
  ].freeze
  METADATA_FIELDS = %w[
    corpus_sha256 corpus_size_bytes corpus_page_count runner execution_environment revision resource_policy
  ].freeze

  # Malformed or unsupported evidence; errors never echo content or paths.
  class EvidenceError < StandardError; end

  EvidenceSample = Struct.new(
    :client, :runner, :execution_environment, :revision, :run_id, :source_sha256, :journey_ids,
    :corpus_kind, :corpus_sha256, :corpus_size_bytes, :corpus_page_count, :cache_state,
    :resource_policy, :boundaries_ms
  )
  EvidenceBundle = Struct.new(:samples)

  module_function

  def fail_with(message) = raise(EvidenceError, message)

  def object(value, fields, label)
    value.is_a?(Hash) && value.keys.to_set == fields.to_set ? value : fail_with("#{label} has missing or unsupported fields")
  end

  def digest(value, size, label)
    return value.downcase if value.is_a?(String) && /\A[a-fA-F0-9]{#{size}}\z/.match?(value)

    fail_with("#{label} must be a hexadecimal digest")
  end

  def positive_integer(value)
    value.is_a?(Integer) && value.positive? ? value : fail_with("corpus counts must be a positive integer")
  end

  def identifier(value)
    return value.downcase if value.is_a?(String) && AppleLatencyEvidence::UUID_PATTERN.match?(value)

    fail_with("run and journey identifiers must be canonical UUIDs")
  end

  def choice(value, allowed, label)
    value.is_a?(String) && allowed.include?(value) ? value : fail_with("unsupported #{label}")
  end

  def load_capture(value, root)
    sample = object(value, CAPTURE_FIELDS, "capture")
    client = choice(sample["client"], DEFAULT_CLIENTS, "client")
    fail_with("web and Flutter profile collectors are not available; leave their evidence pending") if client != "apple"
    environment = choice(sample["execution_environment"], %w[physical_device apple_ci],
                         "Apple environment: use a physical device or compatible Apple CI runner")
    runner = sample["runner"]
    fail_with("runner must be a bounded technical model label, without paths or URLs") unless runner.is_a?(String) && /\A[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}\z/.match?(runner)
    corpus = sample["corpus"]
    keys = corpus.is_a?(Hash) ? corpus.keys.to_set : nil
    fail_with("corpus has missing or unsupported fields") unless keys && Set["kind", "sha256", "size_bytes"] <= keys && keys <= Set["kind", "sha256", "size_bytes", "page_count"]
    kind = choice(corpus["kind"], DEFAULT_CORPORA, "corpus kind")
    corpus_hash = digest(corpus["sha256"], 64, "corpus sha256")
    size = positive_integer(corpus["size_bytes"])
    pages = corpus.key?("page_count") ? positive_integer(corpus["page_count"]) : nil
    fail_with("PDF corpus page_count is required") if kind != "epub" && pages.nil?

    cache = choice(sample["cache_state"], DEFAULT_CACHE_STATES, "cache state")
    policy = choice(sample["resource_policy"], POLICIES, "resource policy")
    revision = digest(sample["revision"], 40, "revision")
    run_id = identifier(sample["run_id"])
    source = digest(sample["source_sha256"], 64, "source sha256")
    journeys = object(sample["journeys"], %w[open play seek], "journeys")
    ids = journeys.to_h { |name, journey| [name, identifier(journey)] }
    boundaries = begin
      AppleLatencyEvidence.load_apple_journeys(
        File.join(root, "artifacts", "#{source}.json"), source, ids, corpus_kind: kind, cache_state: cache
      )
    rescue AppleLatencyEvidence::Error => e
      raise EvidenceError, e.message
    end
    EvidenceSample.new(client, runner, environment, revision, run_id, source, ids.values.freeze, kind,
                       corpus_hash, size, pages, cache, policy, boundaries)
  end

  def validate_identity(samples)
    samples = samples.to_a
    runs = Set.new
    journeys = Set.new
    corpora = {}
    samples.each do |sample|
      fail_with("run or journey identity was reused across captures") if runs.include?(sample.run_id) || sample.journey_ids.any? { |id| journeys.include?(id) }
      runs << sample.run_id
      journeys.merge(sample.journey_ids)
      metadata = [sample.corpus_kind, sample.corpus_size_bytes, sample.corpus_page_count]
      corpora[sample.corpus_sha256] ||= metadata
      fail_with("the same corpus digest has conflicting metadata") if corpora[sample.corpus_sha256] != metadata
    end
    samples
  end

  # Import an explicit local manifest and its content-addressed Apple exports.
  def load_evidence(path)
    payload = begin
      AppleLatencyEvidence.decode_json(File.binread(path))
    rescue AppleLatencyEvidence::DuplicateKey
      fail_with("duplicate manifest field")
    rescue AppleLatencyEvidence::InvalidJson, SystemCallError, IOError
      fail_with("could not read evidence manifest")
    end
    fail_with("evidence schema_version must be #{SCHEMA_VERSION}; manual summaries are not evidence") unless payload.is_a?(Hash) && payload["schema_version"] == SCHEMA_VERSION
    payload = object(payload, %w[schema_version captures], "manifest")
    fail_with("captures must be an array") unless payload["captures"].is_a?(Array)

    root = File.dirname(path.to_s)
    EvidenceBundle.new(validate_identity(payload["captures"].map { |value| load_capture(value, root) }))
  end

  def percentile(values, fraction)
    ordered = values.to_a.sort
    fail_with("percentile requires observations and a fraction between zero and one") if ordered.empty? || !(fraction >= 0 && fraction <= 1)
    offset = (ordered.length - 1) * fraction
    lower = offset.floor
    upper = offset.ceil
    ordered[lower] + ((ordered[upper] - ordered[lower]) * (offset - lower))
  end

  # Python round(): half-even on the exact binary value, preserving signed zero.
  def python_round(value, digits)
    return value unless value.is_a?(Float) && value.finite?

    rounded = Rational(value).round(digits, half: :even).to_f
    rounded.zero? && (value.negative? || (1.0 / value).negative?) ? -0.0 : rounded
  end

  def selection(values, allowed)
    values = values.to_a
    return values unless values.empty? || values.any? { |value| !allowed.include?(value) } || values.uniq != values

    fail_with("required selections must be non-empty, supported and unique")
  end

  def valid_budget?(budget)
    (budget.is_a?(Integer) || budget.is_a?(Float)) && budget.finite? && budget.positive?
  end

  # Report comparable observation cohorts, separately from release readiness.
  def evaluate(samples, clients: DEFAULT_CLIENTS, corpora: DEFAULT_CORPORA, cache_states: DEFAULT_CACHE_STATES,
               required_samples: 20, warm_budget_ms: 200, cold_budget_ms: 1000)
    fail_with("required_samples must be an integer of at least 20") unless required_samples.is_a?(Integer) && required_samples >= 20
    fail_with("budgets must be positive finite numbers") unless [warm_budget_ms, cold_budget_ms].all? { |budget| valid_budget?(budget) }
    clients = selection(clients, DEFAULT_CLIENTS)
    corpora = selection(corpora, DEFAULT_CORPORA)
    cache_states = selection(cache_states, DEFAULT_CACHE_STATES)
    grouped = Hash.new { |hash, key| hash[key] = [] }
    references = {}
    validate_identity(samples).each do |sample|
      key = [sample.client, sample.corpus_kind, sample.cache_state]
      cohort = [sample.corpus_sha256, sample.runner, sample.execution_environment, sample.revision,
                sample.resource_policy]
      grouped[[key, cohort]] << sample
      references[[sample.client, sample.corpus_kind, cohort]] = sample
    end
    buckets = []
    missing = []
    exceeded = []
    clients.each do |client|
      corpora.each do |corpus|
        conditions = references.keys.filter_map { |c, kind, condition| condition if [c, kind] == [client, corpus] }
        conditions = [nil] if conditions.empty?
        cache_states.each do |cache|
          conditions.each do |condition|
            values = grouped.fetch([[client, corpus, cache], condition], [])
            summary = { "client" => client, "corpus" => corpus, "cache_state" => cache, "sample_count" => values.length }
            unless condition.nil?
              first = references[[client, corpus, condition]]
              METADATA_FIELDS.each { |name| summary[name] = first.public_send(name) }
            end
            unless values.empty?
              summary["sources"] = values.map(&:source_sha256).uniq.sort
              summary["run_ids"] = values.map(&:run_id)
              summary["boundaries"] = values.first.boundaries_ms.keys.to_h do |boundary|
                observed = values.map { |sample| sample.boundaries_ms[boundary] }
                [boundary, { "sample_count" => values.length,
                             "p50_ms" => python_round(percentile(observed, 0.5), 3),
                             "p95_ms" => python_round(percentile(observed, 0.95), 3) }]
              end
            end
            if values.length < required_samples
              missing << summary.merge("required_sample_count" => required_samples)
            else
              budget = cache == "relaunch_warm" ? warm_budget_ms : cold_budget_ms
              summary["budget_ms"] = budget
              summary["within_budget"] = true
              %w[reader_usable audio_audible].each do |boundary|
                latency = percentile(values.map { |sample| sample.boundaries_ms[boundary] }, 0.95)
                next unless latency > budget

                summary["within_budget"] = false
                exceeded << summary.except("boundaries", "sources", "run_ids")
                                   .merge("boundary" => boundary, "p95_ms" => latency)
              end
            end
            buckets << summary
          end
        end
      end
    end
    observations_status = if exceeded.any? then "failed" elsif missing.any? then "pending" else "passed" end
    {
      "schema_version" => SCHEMA_VERSION,
      "status" => exceeded.any? ? "failed" : "pending",
      "observations_status" => observations_status,
      "evidence_class" => "imported_diagnostics_not_verified_collection",
      "requirements" => {
        "clients" => clients, "corpora" => corpora, "cache_states" => cache_states,
        "samples_per_bucket" => required_samples, "warm_budget_ms" => warm_budget_ms,
        "cold_budget_ms" => cold_budget_ms
      },
      "buckets" => buckets,
      "missing" => missing,
      "budget_exceeded" => exceeded,
      "pending_requirements" => PENDING_REQUIREMENTS.dup,
      # Stable descending sort, as Python sorted(..., reverse=True).
      "optimization_queue" => exceeded.each_with_index
                                      .sort_by { |item, index| [-(item["p95_ms"].to_f / item["budget_ms"]), index] }
                                      .map(&:first)
    }
  end

  # Minimal argparse-compatible command line handling for main().
  module Cli
    VALUE_OPTIONS = %w[--output --clients --corpora --cache-states --samples].freeze
    OPTION_STRINGS = (%w[-h --help] + VALUE_OPTIONS + %w[--strict]).freeze
    NEGATIVE_NUMBER = /\A-\d+\z|\A-\d*\.\d+\z/

    class UsageError < StandardError; end

    module_function

    def parse(argv, prog)
      options = { "--clients" => DEFAULT_CLIENTS.join(","), "--corpora" => DEFAULT_CORPORA.join(","),
                  "--cache-states" => DEFAULT_CACHE_STATES.join(","), "--samples" => 20 }
      # argparse classifies every argument (raising ambiguity errors) before acting.
      separator = argv.index("--") || argv.length
      classes = argv.each_with_index.map { |argument, at| at < separator ? classify(argument) : [:positional] }
      classes[separator] = [:separator] if separator < argv.length
      evidence = nil
      extras = []
      index = 0
      while index < argv.length
        argument = argv[index]
        kind, name, explicit, sep = classes[index]
        index += 1
        case kind
        when :positional then evidence.nil? ? (evidence = argument) : extras << argument
        when :separator, :unknown then extras << argument if kind == :unknown
        else
          if VALUE_OPTIONS.include?(name)
            if explicit.nil?
              raise UsageError, "argument #{name}: expected one argument" unless classes[index]&.first == :positional

              explicit = argv[index]
              index += 1
            end
            options[name] = name == "--samples" ? integer(explicit) : explicit
            next
          end
          flag_explicit(name, explicit, sep, prog) unless explicit.nil?
          help(prog) unless name == "--strict"
          options["--strict"] = true
        end
      end
      raise UsageError, "the following arguments are required: evidence" if evidence.nil?
      raise UsageError, "unrecognized arguments: #{extras.join(' ')}" unless extras.empty?

      options.merge("evidence" => evidence)
    end

    def classify(argument)
      return [:positional] if argument.empty? || !argument.start_with?("-")
      return [:option, argument, nil] if OPTION_STRINGS.include?(argument)
      return [:positional] if argument.length == 1

      name, explicit = argument.include?("=") ? argument.split("=", 2) : [argument, nil]
      return [:option, name, explicit, true] if OPTION_STRINGS.include?(name)

      if argument.start_with?("--")
        matches = OPTION_STRINGS.select { |option| option.start_with?(name) }
        raise UsageError, "ambiguous option: #{argument} could match #{matches.join(', ')}" if matches.length > 1
        return [:option, matches.first, explicit, !explicit.nil?] if matches.length == 1
      elsif argument.start_with?("-h")
        return [:option, "-h", argument[2..], false]
      end
      return [:positional] if NEGATIVE_NUMBER.match?(argument) || argument.include?(" ")

      [:unknown]
    end

    def flag_explicit(name, explicit, sep, prog)
      label = %w[-h --help].include?(name) ? "-h/--help" : name
      # Python re-reads attached single-dash text (not "=" text) as further short flags.
      remaining = name == "-h" && !sep && !explicit.empty? ? explicit.sub(/\Ah*/, "") : explicit
      raise UsageError, "argument #{label}: ignored explicit argument #{repr(remaining)}" unless remaining.empty? && !sep

      help(prog)
    end

    def integer(text)
      stripped = text.gsub(/\A\s+|\s+\z/, "")
      raise UsageError, "argument --samples: invalid int value: #{repr(text)}" unless /\A[+-]?\d+(?:_\d+)*\z/.match?(stripped)

      Integer(stripped.delete("_"), 10)
    end

    def repr(text)
      quote = text.include?("'") && !text.include?('"') ? '"' : "'"
      escapes = { "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t", quote => "\\#{quote}" }
      body = text.gsub(/[\\#{quote}\x00-\x1f\x7f]/) { |char| escapes[char] || format("\\x%02x", char.ord) }
      "#{quote}#{body}#{quote}"
    end

    # shutil.get_terminal_size(): COLUMNS, then the terminal, then 80; argparse subtracts 2.
    def width
      [Integer(ENV.fetch("COLUMNS", ""), exception: false), IO.console&.winsize&.last, 80].find { |c| c&.positive? } - 2
    rescue StandardError
      78
    end

    def lines(parts, indent, text_width, prefix = nil)
      result = []
      line = []
      length = (prefix ? prefix.length : indent.length) - 1
      parts.each do |part|
        if length + 1 + part.length > text_width && !line.empty?
          result << (indent + line.join(" "))
          line = []
          length = indent.length - 1
        end
        line << part
        length += part.length + 1
      end
      result << (indent + line.join(" ")) unless line.empty?
      result[0] = result[0][indent.length..] if prefix && !result.empty?
      result
    end

    def usage(prog, text_width = width)
      prefix = "usage: "
      optionals = ["[-h]"] + VALUE_OPTIONS.map { |option| "[#{option} #{metavar(option)}]" } + ["[--strict]"]
      positionals = ["evidence"]
      single = ([prog] + optionals + positionals).join(" ")
      return "#{prefix}#{single}\n" if prefix.length + single.length <= text_width

      if prefix.length + prog.length <= 0.75 * text_width
        indent = " " * (prefix.length + prog.length + 1)
        wrapped = lines([prog] + optionals, indent, text_width, prefix) + lines(positionals, indent, text_width)
      else
        indent = " " * prefix.length
        wrapped = lines(optionals + positionals, indent, text_width)
        wrapped = lines(optionals, indent, text_width) + lines(positionals, indent, text_width) if wrapped.length > 1
        wrapped = [prog] + wrapped
      end
      "#{prefix}#{wrapped.join("\n")}\n"
    end

    def metavar(option)
      option.delete_prefix("--").tr("-", "_").upcase
    end

    def wrap(text, text_width, indent = "")
      lines(text.split, indent, text_width).map(&:rstrip)
    end

    def help(prog)
      text_width = [width, 11].max
      position = [24, [text_width - 20, 4].max].min
      rows = [["-h, --help", "show this help message and exit"]] +
             VALUE_OPTIONS.map { |option| ["#{option} #{metavar(option)}", nil] } +
             [["--strict", "Fail until release evidence is complete"]]
      body = rows.map do |invocation, text|
        next "  #{invocation}\n" if text.nil?

        help_lines = wrap(text, [text_width - position, 11].max)
        head = invocation.length <= position - 4 ? "  #{invocation.ljust(position - 4)}  #{help_lines.shift}\n" : "  #{invocation}\n"
        head + help_lines.map { |line| "#{' ' * position}#{line}\n" }.join
      end
      $stdout.write(usage(prog, text_width), "\n", wrap(DESCRIPTION, text_width).join("\n"),
                    "\n\npositional arguments:\n  evidence\n\noptions:\n", body.join)
      exit(0)
    end
  end

  def main(argv = ARGV, prog: File.basename($PROGRAM_NAME))
    begin
      args = Cli.parse(argv, prog)
    rescue Cli::UsageError => e
      $stderr.write(Cli.usage(prog), "#{prog}: error: #{e.message}\n")
      exit(2)
    end
    begin
      report = evaluate(
        load_evidence(args["evidence"]).samples,
        clients: args["--clients"].split(",", -1), corpora: args["--corpora"].split(",", -1),
        cache_states: args["--cache-states"].split(",", -1), required_samples: args["--samples"]
      )
      output = PythonJson.dump(report, indent: 2, sort_keys: true)
      if args["--output"]
        FileUtils.mkdir_p(File.dirname(args["--output"]))
        File.write(args["--output"], "#{output}\n", encoding: "UTF-8")
      end
    rescue EvidenceError, SystemCallError, IOError => e
      message = e.is_a?(EvidenceError) ? e.message : "could not write report"
      warn "performance_evidence_gate: #{message}"
      return 2
    end
    puts output
    args["--strict"] || report["status"] == "failed" ? 1 : 0
  end
end

exit(PerformanceEvidenceGate.main(ARGV)) if $PROGRAM_NAME == __FILE__
