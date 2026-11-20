#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs a command without the native lease it would otherwise inherit.
#
# Every guarded job keeps the lease's open file description so that the lock
# lasts as long as its load does. A test runner that starts a browser or a
# daemon in its own process group would hand that description on, and a
# browser left behind by a cancelled run would then hold the lease until
# someone found and killed it. Started through this wrapper, the runner and
# everything it launches have no lease: the lock then follows the shell that
# runs the suite, which still outlives a killed supervisor.
abort "Usage: without_native_lease.rb COMMAND [ARGUMENTS]" if ARGV.empty?

descriptor = ENV.delete("EPUB_NATIVE_LEASE_FD")
path = ENV.delete("EPUB_NATIVE_LEASE_PATH")
if descriptor&.match?(/\A\d+\z/) && path
  begin
    handle = IO.for_fd(Integer(descriptor), autoclose: false)
    lease = File.stat(path)
    # Only the lease itself is withheld; another file at that number is not ours to close.
    handle.close_on_exec = true if [handle.stat.dev, handle.stat.ino] == [lease.dev, lease.ino]
  rescue SystemCallError, ArgumentError, NotImplementedError
    nil
  end
end
exec([ARGV.first, ARGV.first], *ARGV.drop(1))
