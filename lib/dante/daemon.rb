class Dante
  # A generic daemonizing objec
  class Daemon
    def initialize(name, &process)
      @name = name

      fork do
        (exit if fork); Process.setsid; (exit if fork); store_pid(Process.pid)
        trap("INT") { interrupt; exit }
        trap("TERM") { Dante.logger.add(:warn, "Halting...", @name); exit }
        process.call
        Process.waitpid(pid)
      end
    end
  end
end
