$:.unshift File.expand_path(File.dirname(__FILE__))
require "dante/version"
require "dante/runner"

=begin

  Dante.run("process-name") do
    begin
      # ...something here
    rescue Abort
      # ...shutdown here
    end
  end

=end

module Dante

  # Forks a process and takes some list of params. I don't really know what this does.
  #
  # @example
  #   Dante.run("process-name") { Server.run! }
  #
  def self.run(name, options={}, &blk)
    Runner.new(name, options, &blk).execute!
  end
end
