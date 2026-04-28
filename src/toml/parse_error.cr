module TOML
  # Raised when the input is not valid TOML v1.0.
  #
  # Carries the 1-based line and column where the error was detected,
  # so consumers can point users at the offending byte directly.
  class ParseError < Exception
    getter line : Int32
    getter column : Int32

    def initialize(message : String, @line : Int32, @column : Int32)
      super("#{message} at line #{@line}, column #{@column}")
    end
  end
end
