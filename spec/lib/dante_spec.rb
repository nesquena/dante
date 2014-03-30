require "spec_helper"

describe Dante do
  let(:name) { "example" }
  let(:process) { double("Process") }
  let(:command) { double("Command") }
  let(:dante) { described_class.new(name, process, command) }

  it "should execute the block" do
    allow(command).to receive(:options).and_return({})
    expect(process).to receive(:call).with({})
    dante
  end

  it "should get options from the command" do
    allow(process).to receive(:call)
    expect(command).to receive(:options)
    dante
  end

  describe ".log_path="
  describe ".log_class="
  describe ".log_rotation="
  describe ".logger="
  describe ".log_path"
  describe ".log_class"
  describe ".log_rotation"
  describe ".logger"
end
