require 'spec_helper'
require 'tempfile'

describe Origen::Utility::Diff do
  def files_differ?(content_a, content_b, options = {})
    Tempfile.create('origen_diff_a') do |file_a|
      Tempfile.create('origen_diff_b') do |file_b|
        file_a.write(content_a)
        file_a.flush
        file_b.write(content_b)
        file_b.flush
        described_class.new(options.merge(file_a: file_a.path, file_b: file_b.path)).diffs?
      end
    end
  end

  it 'detects content changes' do
    expect(files_differ?("one\ntwo\n", "one\nthree\n")).to be(true)
    expect(files_differ?("one\ntwo\n", "one\ntwo\n")).to be(false)
  end

  it 'can ignore blank lines and full-line or inline comments' do
    options = { ignore_blank_lines: true, comment_char: ['println', '//'] }
    generated = "println generated metadata\n// generated metadata\n\nresult\n"
    reference = "println reference metadata\n// reference metadata\nresult\n"

    expect(files_differ?(generated, reference, options)).to be(false)
    expect(files_differ?("value // generated\n", "value // reference\n", comment_char: '//')).to be(false)
  end

  it 'rebuilds its comment matchers when comment_char is changed' do
    Tempfile.create('origen_diff_a') do |file_a|
      Tempfile.create('origen_diff_b') do |file_b|
        file_a.write("value # generated\n")
        file_a.flush
        file_b.write("value # reference\n")
        file_b.flush
        differ = described_class.new(file_a: file_a.path, file_b: file_b.path, comment_char: '//')
        differ.comment_char = '#'
        expect(differ.diffs?).to be(false)
      end
    end
  end
end
