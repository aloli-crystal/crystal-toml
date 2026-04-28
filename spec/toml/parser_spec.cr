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
