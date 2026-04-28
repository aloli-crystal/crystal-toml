require "../spec_helper"

private def doc(src : String) : TOML::Document
  TOML.parse(src)
end

private def round_trip!(src : String) : Nil
  TOML.parse(src).to_toml.should eq(src)
end

describe TOML::Parser do
  # ------------------------------------------------------------------
  # Empty / trivia-only documents
  # ------------------------------------------------------------------

  describe "trivia-only documents" do
    it "round-trips an empty document" do
      round_trip!("")
    end

    it "round-trips a single newline" do
      round_trip!("\n")
    end

    it "round-trips a comment-only document" do
      round_trip!("# hello world\n")
    end

    it "round-trips a comment without trailing newline" do
      round_trip!("# tail comment")
    end

    it "round-trips multiple blank lines and comments" do
      round_trip!("# one\n\n# two\n\n\n# three\n")
    end

    it "round-trips a CRLF document" do
      round_trip!("# alpha\r\n\r\n# beta\r\n")
    end
  end

  # ------------------------------------------------------------------
  # Simple key/value pairs
  # ------------------------------------------------------------------

  describe "key/value pairs" do
    it "parses a basic-string value" do
      d = doc(%(name = "Tom"))
      d.nodes.size.should eq(1)
      kv = d.nodes[0].as(TOML::KeyValueLine)
      kv.key.path.should eq(["name"])
      v = kv.value.as(TOML::StringValue)
      v.kind.should eq(TOML::StringValue::Kind::Basic)
      v.decoded.should eq("Tom")
    end

    it "decodes basic-string escape sequences" do
      d = doc(%(s = "a\\nb\\tc\\u00e9"))
      v = d.nodes[0].as(TOML::KeyValueLine).value.as(TOML::StringValue)
      v.decoded.should eq("a\nb\tcé")
    end

    it "parses a literal string verbatim (no escapes)" do
      d = doc(%(path = 'C:\\Users\\Tom'))
      v = d.nodes[0].as(TOML::KeyValueLine).value.as(TOML::StringValue)
      v.decoded.should eq("C:\\Users\\Tom")
    end

    it "parses a multi-line basic string and trims the leading newline" do
      d = doc("s = \"\"\"\nline1\nline2\"\"\"\n")
      v = d.nodes[0].as(TOML::KeyValueLine).value.as(TOML::StringValue)
      v.decoded.should eq("line1\nline2")
    end

    it "parses an integer" do
      v = doc("n = 42").nodes[0].as(TOML::KeyValueLine).value.as(TOML::IntegerValue)
      v.int_value.should eq(42_i64)
    end

    it "parses a signed integer" do
      v = doc("n = -1_000").nodes[0].as(TOML::KeyValueLine).value.as(TOML::IntegerValue)
      v.int_value.should eq(-1000_i64)
    end

    it "parses a hex integer with underscores" do
      v = doc("n = 0xDEAD_BEEF").nodes[0].as(TOML::KeyValueLine).value.as(TOML::IntegerValue)
      v.int_value.should eq(0xDEADBEEF_i64)
    end

    it "parses an octal integer" do
      v = doc("n = 0o755").nodes[0].as(TOML::KeyValueLine).value.as(TOML::IntegerValue)
      v.int_value.should eq(493_i64)
    end

    it "parses a binary integer" do
      v = doc("n = 0b1010").nodes[0].as(TOML::KeyValueLine).value.as(TOML::IntegerValue)
      v.int_value.should eq(10_i64)
    end

    it "parses a float reassembled from atom-dot-atom" do
      v = doc("pi = 3.14").nodes[0].as(TOML::KeyValueLine).value.as(TOML::FloatValue)
      v.float_value.should eq(3.14)
    end

    it "parses a float with exponent (single atom)" do
      v = doc("x = 1e10").nodes[0].as(TOML::KeyValueLine).value.as(TOML::FloatValue)
      v.float_value.should eq(1e10)
    end

    it "parses inf and nan" do
      doc("a = inf").nodes[0].as(TOML::KeyValueLine).value.as(TOML::FloatValue).float_value.infinite?.should eq(1)
      doc("a = -inf").nodes[0].as(TOML::KeyValueLine).value.as(TOML::FloatValue).float_value.infinite?.should eq(-1)
      doc("a = nan").nodes[0].as(TOML::KeyValueLine).value.as(TOML::FloatValue).float_value.nan?.should be_true
    end

    it "parses true and false" do
      doc("a = true").nodes[0].as(TOML::KeyValueLine).value.as(TOML::BooleanValue).bool_value.should be_true
      doc("a = false").nodes[0].as(TOML::KeyValueLine).value.as(TOML::BooleanValue).bool_value.should be_false
    end
  end

  # ------------------------------------------------------------------
  # Datetimes
  # ------------------------------------------------------------------

  describe "datetimes" do
    it "parses a local date" do
      v = doc("d = 1979-05-27").nodes[0].as(TOML::KeyValueLine).value
      v.should be_a(TOML::LocalDateValue)
      ld = v.as(TOML::LocalDateValue)
      ld.date.year.should eq(1979)
      ld.date.month.should eq(5)
      ld.date.day.should eq(27)
    end

    it "parses a local time without fraction" do
      v = doc("t = 07:32:00").nodes[0].as(TOML::KeyValueLine).value
      v.should be_a(TOML::LocalTimeValue)
      span = v.as(TOML::LocalTimeValue).time_of_day
      span.should eq(Time::Span.new(hours: 7, minutes: 32, seconds: 0))
    end

    it "parses a local time with fractional seconds" do
      v = doc("t = 07:32:00.999").nodes[0].as(TOML::KeyValueLine).value.as(TOML::LocalTimeValue)
      span = v.time_of_day
      span.should eq(
        Time::Span.new(hours: 7, minutes: 32, seconds: 0) +
        Time::Span.new(nanoseconds: 999_000_000)
      )
    end

    it "parses a local datetime" do
      v = doc("dt = 1979-05-27T07:32:00").nodes[0].as(TOML::KeyValueLine).value.as(TOML::LocalDateTimeValue)
      v.time.year.should eq(1979)
      v.time.hour.should eq(7)
    end

    it "accepts the lowercase 't' delimiter" do
      v = doc("dt = 1979-05-27t07:32:00").nodes[0].as(TOML::KeyValueLine).value
      v.should be_a(TOML::LocalDateTimeValue)
    end

    it "parses an offset datetime with Z" do
      v = doc("dt = 1979-05-27T07:32:00Z").nodes[0].as(TOML::KeyValueLine).value.as(TOML::OffsetDateTimeValue)
      v.time.offset.should eq(0)
      v.time.year.should eq(1979)
      v.time.hour.should eq(7)
    end

    it "parses an offset datetime with +hh:mm" do
      v = doc("dt = 1979-05-27T00:32:00-07:00").nodes[0].as(TOML::KeyValueLine).value.as(TOML::OffsetDateTimeValue)
      # 00:32 at -07:00 == 07:32 UTC
      v.time.to_utc.hour.should eq(7)
    end

    it "parses an offset datetime with fractional seconds" do
      v = doc("dt = 1979-05-27T07:32:00.999999-07:00").nodes[0].as(TOML::KeyValueLine).value.as(TOML::OffsetDateTimeValue)
      v.time.nanosecond.should eq(999_999_000)
    end

    it "round-trips a datetime byte-identically" do
      round_trip!("dt = 1979-05-27T07:32:00.999999-07:00\n")
    end

    it "rejects an invalid hour" do
      expect_raises(TOML::ParseError, /invalid time component/) do
        doc("t = 25:00:00\n")
      end
    end

    it "rejects an invalid month" do
      expect_raises(TOML::ParseError, /invalid datetime/) do
        doc("d = 1979-13-01\n")
      end
    end
  end

  # ------------------------------------------------------------------
  # Keys
  # ------------------------------------------------------------------

  describe "keys" do
    it "parses a bare key" do
      doc("server_1 = 1").nodes[0].as(TOML::KeyValueLine).key.path.should eq(["server_1"])
    end

    it "parses a quoted key" do
      doc(%("127.0.0.1" = 1)).nodes[0].as(TOML::KeyValueLine).key.path.should eq(["127.0.0.1"])
    end

    it "parses a literal-quoted key" do
      doc("'a.b.c' = 1").nodes[0].as(TOML::KeyValueLine).key.path.should eq(["a.b.c"])
    end

    it "parses a dotted key" do
      doc("physical.shape = 1").nodes[0].as(TOML::KeyValueLine).key.path.should eq(["physical", "shape"])
    end

    it "parses a dotted key with whitespace around the dot" do
      doc("physical . shape = 1").nodes[0].as(TOML::KeyValueLine).key.path.should eq(["physical", "shape"])
    end

    it "parses a mixed bare/quoted dotted key" do
      doc(%(site."a.b".key = 1)).nodes[0].as(TOML::KeyValueLine).key.path.should eq(["site", "a.b", "key"])
    end
  end

  # ------------------------------------------------------------------
  # Tables and arrays-of-tables
  # ------------------------------------------------------------------

  describe "table headers" do
    it "parses a simple table header" do
      d = doc("[server]\n")
      d.nodes.size.should eq(1)
      h = d.nodes[0].as(TOML::TableHeaderLine)
      h.key.path.should eq(["server"])
    end

    it "parses a dotted table header" do
      h = doc("[a.b.c]\n").nodes[0].as(TOML::TableHeaderLine)
      h.key.path.should eq(["a", "b", "c"])
    end

    it "parses an array-of-tables header" do
      h = doc("[[products]]\n").nodes[0].as(TOML::ArrayOfTablesLine)
      h.key.path.should eq(["products"])
    end
  end

  # ------------------------------------------------------------------
  # Arrays
  # ------------------------------------------------------------------

  describe "arrays" do
    it "parses an empty array" do
      v = doc("a = []").nodes[0].as(TOML::KeyValueLine).value.as(TOML::ArrayValue)
      v.items.should be_empty
      v.raw.should eq("[]")
    end

    it "parses a flat array of integers" do
      v = doc("a = [1, 2, 3]").nodes[0].as(TOML::KeyValueLine).value.as(TOML::ArrayValue)
      v.items.size.should eq(3)
      v.items.map(&.as(TOML::IntegerValue).int_value).should eq([1_i64, 2_i64, 3_i64])
    end

    it "parses a heterogeneous array" do
      v = doc(%(a = [1, "two", true])).nodes[0].as(TOML::KeyValueLine).value.as(TOML::ArrayValue)
      v.items[0].should be_a(TOML::IntegerValue)
      v.items[1].should be_a(TOML::StringValue)
      v.items[2].should be_a(TOML::BooleanValue)
    end

    it "accepts a trailing comma" do
      v = doc("a = [1, 2, 3,]").nodes[0].as(TOML::KeyValueLine).value.as(TOML::ArrayValue)
      v.items.size.should eq(3)
      v.raw.should eq("[1, 2, 3,]")
    end

    it "parses a multi-line array with comments" do
      src = <<-TOML
        a = [
          1,    # one
          2,    # two
          3,
        ]
        TOML
      v = doc(src + "\n").nodes[0].as(TOML::KeyValueLine).value.as(TOML::ArrayValue)
      v.items.size.should eq(3)
    end

    it "round-trips a multi-line array byte-identically" do
      src = "a = [\n  1,    # one\n  2,    # two\n  3,\n]\n"
      round_trip!(src)
    end

    it "parses nested arrays" do
      v = doc("a = [[1, 2], [3, 4]]").nodes[0].as(TOML::KeyValueLine).value.as(TOML::ArrayValue)
      v.items.size.should eq(2)
      inner = v.items[0].as(TOML::ArrayValue)
      inner.items.size.should eq(2)
      inner.items.map(&.as(TOML::IntegerValue).int_value).should eq([1_i64, 2_i64])
    end
  end

  # ------------------------------------------------------------------
  # Inline tables
  # ------------------------------------------------------------------

  describe "inline tables" do
    it "parses an empty inline table" do
      v = doc("t = {}").nodes[0].as(TOML::KeyValueLine).value.as(TOML::InlineTableValue)
      v.pairs.should be_empty
      v.raw.should eq("{}")
    end

    it "parses a flat inline table" do
      v = doc(%(t = { name = "Tom", age = 30 })).nodes[0].as(TOML::KeyValueLine).value.as(TOML::InlineTableValue)
      v.pairs.size.should eq(2)
      v.pairs[0][0].should eq(["name"])
      v.pairs[0][1].as(TOML::StringValue).decoded.should eq("Tom")
      v.pairs[1][0].should eq(["age"])
      v.pairs[1][1].as(TOML::IntegerValue).int_value.should eq(30_i64)
    end

    it "parses an inline table with a dotted key" do
      v = doc(%(t = { a.b = 1, c = 2 })).nodes[0].as(TOML::KeyValueLine).value.as(TOML::InlineTableValue)
      v.pairs.size.should eq(2)
      v.pairs[0][0].should eq(["a", "b"])
      v.pairs[1][0].should eq(["c"])
    end

    it "expands dotted-key inline tables in parse_to_hash" do
      h = TOML.parse_to_hash(%(t = { a.b = 1, c = 2 }))
      t = h["t"].as(Hash(String, TOML::Type))
      t["a"].as(Hash(String, TOML::Type))["b"].should eq(1_i64)
      t["c"].should eq(2_i64)
    end

    it "rejects a trailing comma" do
      expect_raises(TOML::ParseError, /trailing comma/) do
        doc(%(t = { a = 1, }))
      end
    end

    it "rejects a newline inside an inline table" do
      expect_raises(TOML::ParseError) do
        doc("t = { a = 1,\n b = 2 }")
      end
    end

    it "round-trips an inline table byte-identically" do
      round_trip!(%(t = { a = 1, b = "two", c = [1, 2] }
))
    end
  end

  # ------------------------------------------------------------------
  # Round-trip preservation
  # ------------------------------------------------------------------

  describe "round-trip preservation" do
    it "preserves a key/value with surrounding whitespace and a comment" do
      round_trip!(%(  name   =   "Tom"   # comment
))
    end

    it "preserves a multi-section document with mixed trivia" do
      src = <<-TOML
        # configuration root
        title = "Example"

        [server]
        # listen on
        host = "0.0.0.0"
        port = 8080

        [[products]]
        name = "Hammer"
        sku  = 738594937
        TOML
      # heredoc strips the indentation; add the final newline.
      round_trip!(src + "\n")
    end

    it "preserves a quoted-key dotted path" do
      round_trip!(%(site."x.y".key = 1
))
    end

    it "preserves \\r\\n line endings throughout" do
      round_trip!("# alpha\r\nname = \"Tom\"\r\n[srv]\r\nport = 80\r\n")
    end
  end

  # ------------------------------------------------------------------
  # Errors
  # ------------------------------------------------------------------

  describe "errors" do
    it "rejects a key without an equals sign" do
      expect_raises(TOML::ParseError, /expected '='/) do
        doc("key value\n")
      end
    end

    it "rejects an unterminated table header" do
      expect_raises(TOML::ParseError, /expected '\]'/) do
        doc("[server\n")
      end
    end

    it "rejects an invalid bare-key character" do
      expect_raises(TOML::ParseError, /invalid character/) do
        doc("a:b = 1\n")
      end
    end

    it "rejects a stray token after the value" do
      expect_raises(TOML::ParseError, /expected newline/) do
        doc("a = 1 garbage\n")
      end
    end
  end
end
