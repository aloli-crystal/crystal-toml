require "./spec_helper"

describe TOML do
  describe "VERSION" do
    it "is set" do
      TOML::VERSION.should_not be_empty
    end
  end

  describe "SPEC_VERSION" do
    it "targets TOML v1.0" do
      TOML::SPEC_VERSION.should eq("1.0.0")
    end
  end
end
