class Dante
  # Collecing the arguments passed to the CLI binary
  class Command
    attr_reader :options

    def initialize(&parser)
      @options = AltStruct.new
      @parser = OptionParser.new(&parser)
    end

    def options
      options.tap do
        @parser.parse!
      end
    end
  end
end
