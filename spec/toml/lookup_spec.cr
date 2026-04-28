require "../spec_helper"

describe "TOML::Document lookup API" do
  doc = TOML.parse(<<-TOML)
    title = "Example"
    port  = 8080
    pi    = 3.14
    on    = true
    when  = 1979-05-27T07:32:00Z
    dur   = 07:32:00

    [server]
    host = "0.0.0.0"

    [server.tls]
    cert = "/etc/cert.pem"
    TOML

  describe "#has_key?" do
    it "is true for an existing top-level key" do
      doc.has_key?("title").should be_true
    end

    it "is true for a nested key" do
      doc.has_key?("server.tls.cert").should be_true
    end

    it "is false for a missing key" do
      doc.has_key?("nope").should be_false
      doc.has_key?("server.nope").should be_false
    end
  end

  describe "#get? / #get" do
    it "returns the value for an existing path" do
      doc.get?("title").should eq("Example")
      doc.get?("server.host").should eq("0.0.0.0")
    end

    it "returns nil for a missing path" do
      doc.get?("nope").should be_nil
      doc.get?("server.tls.nope").should be_nil
    end

    it "raises KeyError on #get when missing" do
      expect_raises(KeyError) do
        doc.get("nope")
      end
    end
  end

  describe "typed accessors" do
    it "reads strings" do
      doc.string("title").should eq("Example")
      doc.string?("title").should eq("Example")
      doc.string?("port").should be_nil
    end

    it "reads integers" do
      doc.int("port").should eq(8080_i64)
      doc.int?("port").should eq(8080_i64)
      doc.int?("title").should be_nil
    end

    it "reads floats" do
      doc.float("pi").should eq(3.14)
      doc.float?("title").should be_nil
    end

    it "reads booleans" do
      doc.bool("on").should be_true
      doc.bool?("title").should be_nil
    end

    it "reads datetimes" do
      doc.datetime?("when").should_not be_nil
      doc.datetime("when").year.should eq(1979)
    end

    it "reads time-of-day" do
      doc.time_of_day("dur").should eq(Time::Span.new(hours: 7, minutes: 32, seconds: 0))
    end

    it "raises TypeCastError when the type is wrong" do
      expect_raises(TypeCastError, /expected String/) do
        doc.string("port")
      end
      expect_raises(TypeCastError, /expected Int64/) do
        doc.int("title")
      end
    end
  end

  describe "Array(String) path form" do
    it "looks up a path that contains a dot in a key segment" do
      d = TOML.parse(%("a.b" = 1
[server]
"with.dot" = 2
))
      d.get?(["a.b"]).should eq(1_i64)
      d.get?(["server", "with.dot"]).should eq(2_i64)
    end
  end
end
