require "spec_helper"

class BugsDut
  include Origen::TopLevel
  attr_reader :version

  bug :low_vref, affected_version: 0
  bug :low_iref, affected_versions: [0, 1]
  bug :dac_code, fixed_on_version: 1
  bug :bug1, unfixable: true

  def initialize(version)
    @version = version
  end
end

class UnversionedBugsDut
  include Origen::Bugs

  bug :my_bug, unfixable: true
  bug :ordinary_bug
end

describe "Bugs API" do

  after :all do
    Origen.load_target("debug")
  end

  it "bug objects are created" do
    Origen.load_target("configurable", dut: BugsDut, version: 0)
    $dut.bugs.size.should == 4
    $dut.bugs.all? { |name, bug| bug.is_a?(Origen::Bugs::Bug) }.should == true
  end

  it "bug presence methods are generated" do
    Origen.load_target("configurable", dut: BugsDut, version: 0)
    $dut.has_bug?(:low_vref).should == true
    $dut.has_bug?(:low_iref).should == true
    $dut.has_bug?(:dac_code).should == true
    $dut.has_bug?(:bug1).should == true
    $dut.has_bug?(:undefined).should == false
  end

  it "fixed on version is the one after the last affected version unless specified" do
    Origen.load_target("configurable", dut: BugsDut, version: 0)
    $dut.bugs[:low_iref].fixed_on_version.should == 2
    $dut.bugs[:dac_code].fixed_on_version.should == 1
    $dut.bugs[:bug1].fixed_on_version.should == nil
  end

  it "explicitly unfixable bugs can be queried without a version" do
    dut = UnversionedBugsDut.new
    dut.bugs[:my_bug].unfixable?.should == true
    dut.has_bug?(:my_bug).should == true
    lambda { dut.has_bug?(:ordinary_bug) }.should raise_error(RuntimeError, 'Version undefined!')
  end

  it "bug presence methods scope to the current version" do
    Origen.load_target("configurable", dut: BugsDut, version: 1)
    $dut.has_bug?(:low_vref).should == false
    $dut.has_bug?(:low_iref).should == true
    $dut.has_bug?(:dac_code).should == false
    $dut.has_bug?(:bug1).should == true
    Origen.load_target("configurable", dut: BugsDut, version: 2)
    $dut.has_bug?(:low_vref).should == false
    $dut.has_bug?(:low_iref).should == false
    $dut.has_bug?(:dac_code).should == false
    $dut.has_bug?(:bug1).should == true
  end

end
