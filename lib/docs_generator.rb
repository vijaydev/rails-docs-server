require 'logging'
require 'docs_compressor'
require 'git_manager'

Dir.glob("#{__dir__}/target/*.rb") do |target|
  require target unless File.basename(target) == 'base.rb'
end

# This class is responsible for coordinating docs generation.
#
# The documentation is generated below `basedir`. There, each release and master
# have their own directory:
#
#   tag1
#   tag2
#   tag3
#   ...
#   tagN
#   master
#
# Then it checks the tags of the project and detects new releases in any of the
# branches. If there are any (from 3.2 up), the corresponding target class is
# responsible for the actual generations. The target class is who knows which
# ruby and bundler versions it needs, which are the directories for API and
# guides, and how are they generated.
#
# Top-level symlinks point to the actual root directories. If we assume v4.1.0
# is the current stable release, this is the idea:
#
#   api/v3.2.0 -> basedir/v3.2.0/doc/rdoc
#   api/v4.1.0 -> basedir/v4.1.0/doc/rdoc
#   api/stable -> basedir/api/v4.1.0
#   api/edge   -> basedir/master/doc/rdoc
#
# and same for guides:
#
#   guides/v3.2.0 -> basedir/v3.2.0/railties/guides/output
#   guides/v4.1.0 -> basedir/v4.1.0/guides/output
#   guides/stable -> basedir/guides/v4.1.0
#   guides/edge   -> basedir/master/guides/output
#
# If new releases are detected, symlinks are adjusted as needed.
#
# Once everything related to stable docs is done, edge docs are generated.
#
# Documentation files are further compressed to leverage nginz gzip_static.
#
# The docs generator assumes a master directory with an up to date working
# copy, it is the responsability of the caller to get that in place via the
# git manager. It is also the responsibility of the caller to ensure there is
# only one generator being executed at the same time.
class DocsGenerator
  include Logging

  API    = 'api'
  GUIDES = 'guides'
  STABLE = 'stable'
  EDGE   = 'edge'

  attr_reader :basedir, :git_manager

  def initialize(basedir, git_manager=GitManager.new(basedir))
    @basedir     = File.expand_path(basedir)
    @git_manager = git_manager
  end

  def generate
    Dir.chdir(basedir) do
      generate_stable_docs
      generate_edge_docs
    end
  end

  def generate_stable_docs
    new_stable_docs = false

    git_manager.release_tags.each do |tag|
      if generate_stable_docs_for?(tag)
        generate_stable_docs_for(tag)
        new_stable_docs = true
      end
    end

    adjust_stable_symlinks if new_stable_docs
  end

  def generate_stable_docs_for?(tag)
    major, minor = version(tag)
    (major > 3 || (major == 3 && minor == 2)) && !Dir.exists?(tag)
  end

  def generate_stable_docs_for(tag)
    git_manager.checkout(tag)

    generator = stable_generator_for(tag)
    generator.generate

    DocsCompressor.new(generator.api_output).compress
    DocsCompressor.new(generator.guides_output).compress

    create_api_symlink(generator.api_output, tag)
    create_guides_symlink(generator.guides_output, tag)
  end

  def generate_edge_docs
    generator = Target::Master.new(git_manager.short_sha1, 'master')
    generator.generate

    DocsCompressor.new(generator.api_output).compress
    DocsCompressor.new(generator.guides_output).compress

    # Force the recreation of the symlink to be forward compatible, if the docs
    # structure changes in master we need the symlink to point to the new dirs.
    create_api_symlink(generator.api_output, EDGE, force: true)
    create_guides_symlink(generator.guides_output, EDGE, force: true)
  end

  # TODO: auto-discover the klass. Exact match first, most recent class within
  # the ordered collection of versions second.
  def stable_generator_for(tag)
    if tag.start_with?('v3.2.')
      Target::V3_2_x
    elsif tag == 'v4.0.0'
      Target::V4_0_0
    elsif tag.start_with?('v4.0.') or tag.start_with?('v4.1.')
      Target::V4_0_1
    elsif tag == 'v4.2.0'
      Target::V4_2_0
    else
      Target::Current
    end.new(tag, tag)
  end

  def create_api_symlink(origin, symlink, options={})
    create_symlink(API, origin, symlink, options)
  end

  def create_guides_symlink(origin, symlink, options={})
    create_symlink(GUIDES, origin, symlink, options)
  end

  def create_symlink(dir, origin, symlink, options)
    FileUtils.mkdir_p(dir)

    Dir.chdir(dir) do
      FileUtils.rm_f(symlink) if options[:force]
      File.symlink(origin, symlink)
    end
  end

  def adjust_stable_symlinks
    st = stable_tag

    [API, GUIDES].each do |_|
      Dir.chdir(_) do
        unless File.exists?(STABLE) && File.readlink(STABLE) == st
          FileUtils.rm_f(STABLE)
          File.symlink(st, STABLE)
        end
      end
    end
  end

  def stable_tag
    stable_tag = 'v0.0.0'

    foreach_tag do |tag|
      stable_tag = tag if compare_tags(stable_tag, tag) == -1
    end

    stable_tag
  end

  def compare_tags(tag1, tag2)
    version1 = version(tag1)
    version1[3] ||= 0 # tiny

    version2 = version(tag2)
    version2[3] ||= 0 # tiny

    version1 <=> version2
  end

  def version(tag)
    tag.scan(/\d+/).map(&:to_i)
  end

  def foreach_tag
    Dir.foreach(basedir) do |fname|
      yield fname if File.basename(fname) =~ /\Av[\d.]+\z/
    end
  end
end
