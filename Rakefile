require "bundler/setup"
Bundler::GemHelper.install_tasks

require "rake/testtask"

Rake::TestTask.new do |t|
  t.libs << "spec" << "lib"
  t.pattern = "spec/**/*_spec.rb"
  t.warning = false
end

task(default: :test)

task :test => :html_proofer

def load_gem_and_dummy
  $:.push File.expand_path("../lib", __FILE__)
  $:.push File.expand_path("../spec", __FILE__)
  require "graphql"
  require "./spec/support/dairy_app"
end

task :console do
  require "irb"
  require "irb/completion"
  load_gem_and_dummy
  ARGV.clear
  IRB.start
end

desc "Test the generated HTML files"
task :html_proofer do
  require "html-proofer"
  system "bundle exec jekyll build"
  config = {
    :assume_extension => true
  }
  HTMLProofer.check_directory("./_site", config).run
end

desc "Use Racc & Ragel to regenerate parser.rb & lexer.rb from configuration files"
task :build_parser do
  `rm lib/graphql/language/parser.rb lib/graphql/language/lexer.rb `
  `racc lib/graphql/language/parser.y -o lib/graphql/language/parser.rb`
  `ragel -R lib/graphql/language/lexer.rl`
end

namespace :site do
  desc "View the documentation site locally"
  task :serve do
    system "jekyll serve --config '_config.yml,guides/_config.dev.yml'"
  end

  desc "Commit the local site to the gh-pages branch and publish to GitHub Pages"
  task :publish do
    # Ensure the gh-pages dir exists so we can generate into it.
    puts "Checking for gh-pages dir..."
    unless File.exist?("./gh-pages")
      puts "Creating gh-pages dir..."
      sh "git clone git@github.com:rmosolgo/graphql-ruby gh-pages"
    end

    # Ensure latest gh-pages branch history.
    Dir.chdir('gh-pages') do
      sh "git checkout gh-pages"
      sh "git pull origin gh-pages"
    end

    # Proceed to purge all files in case we removed a file in this release.
    puts "Cleaning gh-pages directory..."
    purge_exclude = %w[
      gh-pages/.
      gh-pages/..
      gh-pages/.git
      gh-pages/.gitignore
    ]
    FileList["gh-pages/{*,.*}"].exclude(*purge_exclude).each do |path|
      sh "rm -rf #{path}"
    end

    # Copy site to gh-pages dir.
    puts "Building site into gh-pages branch..."
    ENV['JEKYLL_ENV'] = 'production'
    require "jekyll"
    Jekyll::Commands::Build.process({
      "source"       => File.expand_path("guides"),
      "destination"  => File.expand_path("gh-pages"),
      "sass"         => { "style" => "compressed" }
    })

    File.open('gh-pages/.nojekyll', 'wb') { |f| f.puts(":dog: food.") }

    # Commit and push.
    puts "Committing and pushing to GitHub Pages..."
    sha = `git rev-parse HEAD`.strip
    Dir.chdir('gh-pages') do
      sh "git add ."
      sh "git commit --allow-empty -m 'Updating to #{sha}.'"
      sh "git push origin gh-pages"
    end
    puts 'Done.'
  end
end
