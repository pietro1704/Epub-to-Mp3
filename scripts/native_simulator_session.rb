#!/usr/bin/env ruby
# frozen_string_literal: true

# Production remains quarantined while the process contract is implemented.
module NativeSimulatorSession
  def self.run(plan_path:, backend:, lock_path:, report_path:)
    75
  end

  def self.main(_arguments)
    warn "Simulator sessions remain quarantined pending supervised execution review."
    75
  end
end

exit NativeSimulatorSession.main(ARGV) if $PROGRAM_NAME == __FILE__
