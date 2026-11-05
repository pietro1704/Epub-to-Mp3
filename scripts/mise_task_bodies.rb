# frozen_string_literal: true

require "json"
require "open3"

# Read resolved task bodies once per suite, without starting any task or caching
# across roots/processes. Keep mise's environment and platform resolution.
module MiseTaskBodies
  def self.load(root, names)
    output, error, status = Open3.capture3("mise", "tasks", "ls", "--json", "--hidden", chdir: root)
    raise "Cannot read mise tasks: #{error}" unless status.success?

    tasks = JSON.parse(output).to_h { |task| [task.fetch("name"), task] }
    names.to_h { |name| [name, tasks.fetch(name).fetch("run").join("\n")] }
  end
end
