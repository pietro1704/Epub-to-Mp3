# frozen_string_literal: true

# Helpers that keep CLI contracts of host scripts ported from Python: an
# argparse-compatible parser (Python 3.14 messages, exit status 2).
module PythonCliCompat
  # Subset of argparse: -h/--help, long options taking one value (:value) or
  # none (:flag), unique-prefix abbreviations, --opt=value and one optional
  # positional with nargs="*" and choices.
  class ArgumentParser
    def initialize(prog:, usage:, help:, options:, positional: nil)
      @prog = prog
      @usage = usage
      @help = help
      @options = options
      @positional = positional
    end

    def parse(argv)
      values = @options.values.to_h { |spec| [spec[:dest], spec[:kind] == :flag ? false : nil] }
      values[@positional[:dest]] = nil if @positional
      seen = []
      extras = []
      positional_done = @positional.nil?
      separator = false
      index = 0
      while index < argv.length
        argument = argv[index]
        index += 1
        if !separator && argument == "--"
          separator = true
          next
        end
        kind, name, explicit = separator ? [:value] : classify(argument)
        case kind
        when :value
          if positional_done
            extras << argument
          else
            run = [argument]
            while index < argv.length && (separator || classify(argv[index]).first == :value) && argv[index] != "--"
              run << argv[index]
              index += 1
            end
            values[@positional[:dest]] = run.each { |item| check_choice(item) }
            positional_done = true
          end
        when :unknown then extras << argument
        else
          index = consume(name, explicit, argv, index, values, seen) { separator = true }
        end
      end
      missing = @options.select { |_, spec| spec[:required] && !seen.include?(spec[:dest]) }.keys
      error("the following arguments are required: #{missing.join(", ")}") unless missing.empty?
      error("unrecognized arguments: #{extras.join(" ")}") unless extras.empty?
      values
    end

    private

    def consume(name, explicit, argv, index, values, seen)
      if name == "-h"
        error("argument -h/--help: ignored explicit argument #{explicit.inspect.tr('"', "'")}") if explicit
        $stdout.write(@help)
        exit 0
      end
      spec = @options.fetch(name)
      seen << spec[:dest]
      if spec[:kind] == :flag
        error("argument #{name}: ignored explicit argument #{explicit.inspect.tr('"', "'")}") if explicit
        values[spec[:dest]] = true
        return index
      end
      if explicit.nil?
        if argv[index] == "--" && index + 1 < argv.length
          yield
          explicit = argv[index + 1]
          index += 2
        elsif index < argv.length && argv[index] != "--" && classify(argv[index]).first == :value
          explicit = argv[index]
          index += 1
        else
          error("argument #{name}: expected one argument")
        end
      end
      values[spec[:dest]] = explicit
      index
    end

    def classify(argument)
      return [:value] if !argument.start_with?("-") || argument == "-"
      return [:option, "-h", nil] if argument == "-h" || argument == "--help"
      return [:option, argument, nil] if @options.key?(argument)

      name, explicit = argument.split("=", 2)
      return [:option, name == "--help" ? "-h" : name, explicit] if @options.key?(name) || name == "--help" || name == "-h"
      return [:option, "-h", argument[2..]] if argument.start_with?("-h")

      if argument.start_with?("--")
        matches = (@options.keys + ["--help"]).select { |option| option.start_with?(name) }
        error("ambiguous option: #{name} could match #{matches.join(", ")}") if matches.length > 1
        return [:option, matches.first == "--help" ? "-h" : matches.first, explicit] if matches.length == 1
      end
      return [:value] if argument.match?(/\A-\.?\d/) || argument.include?(" ")

      [:unknown]
    end

    def check_choice(value)
      choices = @positional[:choices]
      return if choices.nil? || choices.include?(value)

      error("argument #{@positional[:dest]}: invalid choice: '#{value}' (choose from #{choices.join(", ")})")
    end

    def error(message)
      $stderr.write("#{@usage}#{@prog}: error: #{message}\n")
      exit 2
    end
  end
end
