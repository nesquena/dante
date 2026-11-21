require File.expand_path('../test_helper', __FILE__)

describe "dante.gemspec" do
  before do
    @root = File.expand_path('../..', __FILE__)
    @spec = Gem::Specification.load(File.join(@root, 'dante.gemspec'))
  end

  it "packages every library file, license, readme and changelog" do
    lib_files = Dir.glob('lib/**/*.rb', base: @root).sort
    lib_files.each do |file|
      assert_includes @spec.files, file
    end
    %w[LICENSE README.md CHANGELOG.md].each do |doc|
      assert_includes @spec.files, doc
    end
    @spec.files.each do |file|
      assert File.file?(File.join(@root, file)), "missing packaged file #{file}"
    end
  end

  it "does not package tests, CI workflows or repo metadata" do
    refute @spec.files.any? { |f| f.start_with?('test/', '.github/') }
    %w[.gitignore Gemfile Rakefile dante.gemspec].each do |dev_file|
      refute_includes @spec.files, dev_file
    end
  end
end
