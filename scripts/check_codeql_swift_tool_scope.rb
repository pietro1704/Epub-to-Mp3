require 'json'
require 'open3'
require 'yaml'

workflow = YAML.safe_load(File.read('.github/workflows/codeql.yml'), aliases: false)
swift = workflow.fetch('jobs').fetch('swift')
environment = swift.fetch('env', {})
abort 'Swift job env must be a mapping' unless environment.is_a?(Hash)
if environment.key?('MISE_ENABLE_TOOLS') && !environment['MISE_ENABLE_TOOLS'].is_a?(String)
  abort 'Swift MISE_ENABLE_TOOLS must be a literal string or absent'
end
filter = environment['MISE_ENABLE_TOOLS']
expected = %w[python ruby rust]
failures = []
{ 'root' => '.', 'Apple project' => 'ios/EpubToMp3' }.each do |label, directory|
  # A missing production filter must remove the harness-only Ruby filter.
  output, error, status = Open3.capture3(
    { 'MISE_ENABLE_TOOLS' => filter },
    'mise', 'ls', '--current', '--json', chdir: directory
  )
  unless status.success?
    failures << "#{label}: mise ls failed (exit #{status.exitstatus}): #{error}"
    next
  end
  warn "#{label}: mise ls diagnostics: #{error}" unless error.strip.empty?
  begin
    tools = JSON.parse(output)
    raise TypeError, 'expected a tool-name mapping' unless tools.is_a?(Hash)
    names = tools.keys.sort
    puts "#{label} Swift tools: #{names.join(', ')}"
    failures << "#{label}: unexpected Swift tools #{names.inspect}; expected #{expected.inspect}" unless names == expected
  rescue JSON::ParserError, TypeError => error
    failures << "#{label}: invalid mise tool manifest: #{error.message}"
  end
end
abort failures.join("\n") unless failures.empty?
