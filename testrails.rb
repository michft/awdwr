#!/usr/bin/ruby
require 'rubygems'
require 'yaml'
require 'ostruct'

unless Kernel.respond_to?(:require_relative)
  module Kernel
    def require_relative(path)
      require File.join(File.dirname(caller[0]), path.to_str)
    end
  end
end

require_relative 'clerk/rvm'
require_relative 'clerk/rbenv'

HOME = ENV['HOME']
ENV['LANG']='en_US.UTF-8'
ENV['USER'] ||= HOME.split(File::Separator).last
File.umask(0022)
$rails = "#{HOME}/git/rails"

# chaining support
if ARGV.join(' ').include?(',')
  ARGV.join(' ').split(',').each { |args| system "#{$0} #{args.strip}" }
  exit
end

# parse ARGV based on configuration
config = YAML.load(open('testrails.yml'))
profile = config['default'].dup
config.each do |keyword,overrides| 
  next unless ARGV.include? keyword.to_s
  overrides.each do |key, value|
    if profile[key].respond_to? :push
      profile[key].push(value)
    else
      profile[key] = value
    end
  end
end
PROFILE = OpenStruct.new(profile)
release=PROFILE.rvm['bin'].split('-')[1]

COMMIT = ARGV.find {|arg| arg =~ /http:\/\/github.com\/rails\/rails\/commit\//}

log=config.find_all {|k,v| v['output'] and ARGV.include? k.to_s}.
  map {|k,v| k}.join('-')
LOG = "#{HOME}/logs/makedepot#{log}.log"
system "mkdir -p #{File.dirname(LOG)}"

OUTPUT = PROFILE.output.map {|token| '-'+token.gsub('.','')}.sort.join
OUTMIN = OUTPUT.gsub('.','')
WORK   = 'work' + OUTMIN
Dir.chdir PROFILE.source do
  system "mkdir -p #{WORK}"
  system "ln -f -s ../data #{WORK}" unless File.exist?(File.join(WORK, 'data'))
end

BRANCH = PROFILE.branch
DESTDIR = PROFILE.destdir
SCRIPT  = File.join(File.expand_path(File.dirname(__FILE__)), PROFILE.script)

# update Rails
if ARGV.delete('noupdate')
  updated = true
else
  updated = Dir.chdir($rails) do
    system 'git checkout -q origin/master'
    system "git checkout #{BRANCH}"
    system "git checkout #{COMMIT.split('/').last}" if COMMIT
    before = `git log -1 --pretty=format:%H`
    print 'rails: '
    system 'git pull origin'
    `git log -1 --pretty=format:%H` != before
  end
end

$rails_version = (File.read("#{$rails}/RAILS_VERSION").strip rescue '2.x')
$rails_version.sub! '3.1.0.rc1', '3.2.0.pre'

# adjust selection based on arguments
arg_was_present = (not ARGV.empty?)
oldest = ARGV.delete('next') unless updated
missing = ARGV.delete('missing')
failed = ARGV.delete('fail') || ARGV.delete('failed')
before = ARGV.find {|c| c.start_with? '<'}; ARGV.delete(before)
arg_was_present = false if oldest and updated

if ARGV.empty? and arg_was_present
  require 'nokogiri'

  dashboard=`ruby /var/www/dashboard.cgi static`.sub(/.*?</m,'<')
  rows = Nokogiri::XML(dashboard).search('tr').to_a
  rows.reject! {|row| !row.at('td')}
  rows.reject! {|row| row.at('td:nth-child(4).hilite')}
  dated = rows.select {|r| r.at('td:last').text =~ /^\d+(-\d+)+.\d+(:\d+)+$/}
  selected = rows - dated

  if oldest
    selected << rows.min {|a,b| a.at('td:last').text <=> b.at('td:last').text}
    selected = selected.slice(0,1)
  elsif before
    before = before.gsub(/\D/, '')
    selected += dated.select {|tr| tr.at('td:last').text.gsub(/\D/,'') < before}
  elsif failed
    selected = rows.select {|tr| tr.at('td.fail')}
  end

  Process.exit if selected.empty?

  args = selected.uniq.map {|tr| 
    tr.search('td').to_a[0..2].map {|td| td.text.gsub('.','')}.join(' ')
  }.join(', ')
  exec "#{$0} #{args}"
end

# clean up mysql
open('|mysql -u root','w') {|f| f.write "drop database depot_production;"}
open('|mysql -u root','w') {|f| f.write "create database depot_production;"}

require_relative 'bootstrap'
gems, libs, repos = dependencies(File.join(HOME, 'git', 'rails'),
  PROFILE.rvm['bin'].split('-')[1])

# adjust gems
%w(
  htmlentities 
  rdoc minitest test-unit
  bcrypt-ruby rvm-capistrano activemerchant haml sqlite3 jquery-rails
).each do |name|
  gems[name] ||= nil unless libs[name]
end

if $rails_version =~ /^3\./
  gems['will_paginate'] ||= nil
else
  gems['kaminari'] ||= nil
end

if $rails_version =~ /^3\.0/
  gems['mysql'] ||= nil
  gems['activemerchant'] ||= ", '~> 1.10.0'"
  gems['haml'] ||= ", '~> 4.0'"
  gems['will_paginate'] ||= ", '>= 3.0.pre'"
else
  gems['mysql2'] ||= nil
  gems['bcrypt-ruby'] ||= nil
end

if release =~ /^1\.8\./
  gems['activemerchant'] ||= ", '~> 1.21.0'"
end

# checkout/update libs
libs.each do |lib, branch|
  print lib + ': '
  if not File.exist? File.join(HOME,'git',lib)
    Dir.chdir(File.join(HOME,'git')) do 
      system "git clone https://github.com/#{repos[lib]}"
    end
  end
  Dir.chdir(File.join(HOME,'git',lib)) do 
    system "git checkout #{branch}"
    system 'git pull'
  end
end

# update gems
Dir.chdir File.join(PROFILE.source,WORK) do
  if File.exist? File.join($rails, 'Gemfile')
    open('Gemfile','w') do |gemfile|
      gemfile.puts "source 'http://rubygems.org'"
      gemfile.puts "gem 'rails', :path => #{$rails.inspect}"
      libs.each do |lib, branch|
        next if lib == 'gorp'
        path = File.join(HOME,'git',lib)
        if File.exist?(File.join(path, "/#{lib}.gemspec"))
          gemfile.puts "gem #{lib.inspect}, :path => #{path.inspect}"
        end
      end
      gems.each {|gem,opts| gemfile.puts "gem #{gem.inspect}#{opts}"}
    end
  else
    system 'rm -f Gemfile'
  end
end

# update awdwr tests
Dir.chdir PROFILE.source
if PROFILE.source.include? 'svn'
  system 'svn up'
else
  print 'awdwr: '
  system 'git checkout -q master'
  system 'git pull origin'
end

# capture the old status
status_file = File.join(WORK, 'checkdepot.status')
if not File.exist?(status_file) and File.exist?(File.join(WORK, 'status'))
  File.rename File.join(WORK, 'status'), status_file
end
OLDSTAT = open(status_file) {|file| file.read} rescue ''
OLDSTAT.gsub! /, 0 (pendings|omissions|notifications)/, ''

# select arguments to pass through
args = ARGV.grep(/^(\d+(\.\d+)?-\d+(\.\d+)?|\d+\.\d+?|save|restore)$/)
args << "--work=#{WORK}"

if PROFILE.path
  ENV['PATH'] = (PROFILE.path + ENV['PATH'].split(':')).uniq.join(':')
end

# select rvm or rbenv
if RVM.available?
  clerk = RVM.new
elsif RBenv.available?
  clerk = RBenv.new
else
  STDERR.puts "Either rvm or rbenv are required"
  exit 1
end

# update build definitions
clerk.update

# build a new ruby, if necessary
source=PROFILE.rvm['src']
version = if source
  clerk.install_from_source(source, release)
else
  clerk.install_latest(PROFILE.rvm['bin'])
end

unless version
  STDERR.puts "#{PROFILE.rvm['bin']} installation failed, exiting..."
  exit 1
end

version = File.basename(version)

# keep the last three, and anything built in a week; remove the rest
clerk.prune(PROFILE.rvm['bin'], 3, Time.now - 7 * 86400)

if File.exist? File.join(WORK, 'Gemfile')
  install, bundler  = 'install', 'bundler'
  gemspec = File.join(HOME, 'git', 'rails', 'rails.gemspec')
  if File.exist?(gemspec)
    if not File.readlines(gemspec).grep(/bundler.*\.pre\./).empty?
      install = 'install --pre' 
      bundler = 'bundler.*pre'
    end
  end

  install = <<-EOF
    gem list bundler | grep -q #{bundler} && gem update bundler || gem #{install} bundler
    (cd #{WORK}; rm -rf Gemfile.lock vendor; bundle install)
  EOF
else
  install = <<-EOF
    gem list rack | grep -q 1.1.3 || gem install rack -v 1.1.3
    gem list will_paginate | grep -q 2.3 || gem install will_paginate -v 2.3.11
    gem list activesupport | grep -q 3.0 && gem uninstall activesupport -I -a
  EOF
end

system "rm -f #{WORK}/checkdepot.html"

# run the script
clerk.run(version, install)

ENV['RUBYLIB'] = libs.keys.map {|lib| File.join(HOME,'git',lib,'lib')}.
  join(File::PATH_SEPARATOR)

clerk.run(version, 
    "ruby #{PROFILE.script} #{$rails} #{args.join(' ')} > #{LOG} 2>&1")

status = $?

if File.exist?("#{WORK}/checkdepot.html")
  # parse and normalize checkdepot output
  body = open("#{WORK}/checkdepot.html").read
  body.gsub! "src='data", "src='../data"
  body.gsub! 'src="data', 'src="../data'
  eof = '#&lt;EOFError: end of file reached&gt;'
  body.gsub! eof, "<a href='makedepot.log'>#{eof}</a>"

  # dissect checkdepot output 
  sections = body.split(/^\s+<a class="toc" id="section-(.*?)">/)
  head=sections.shift
  toc = head.slice!(/^\s*<h2>Table of Contents<\/h2>.*/m)
  sections[-1], env = sections.last.split(/<a class="toc" id="env">/)
  style = head.slice(/<style.*?style>/m)
  head.sub!(/<style.*?style>/m, '<link rel="stylesheet" href="depot.css"/>')
  env = '<a class="toc" id="env">'+env
  tail = env.slice!(/^\s+<\/body>\s*<\/html>/)

  # split out the style, append style information for links
  style.sub! /<style.*\n/, ''
  style.sub! /\s*<\/style>/, ''
  unindent = style.gsub(/\n\s*\n/,"\n").scan(/^ */).map {|str| str.length}.min
  style.gsub! Regexp.new('^'.ljust(unindent+1)), ''
  style+="\n\n"
  style+=".prev_link:before {content: '#{[171].pack('U')} '}\n"
  style+=".next_link:after {content: ' #{[187].pack('U')}'}\n"
  style+=".next_link .prev_link {text-decoration: none}\n"
  style+=".next_link {float: right}\n"

  def page(section)
    "section-#{section}.html"
  end

  # determine the value for previous / next links
  headers=sections.map {|data| data.slice(/\A\s*<h2>.*/)}
  identity = [nil] + sections[0..-2]
  backward=[nil,nil] + identity[0..-3]
  forward=identity[2..-1] + [nil,nil]

  next_link = {sections[-2] => 
    '<a href="index.html" class="next_link">Table of Contents</a>'}
  prev_link = {sections[0] => 
    '<a href="index.html" class="prev_link">Table of Contents</a>'}

  headers.zip(identity,backward,forward).each do |header, this, before, after|
    next unless header
    header.sub!('</h2', '</a').strip!
    next_link[before] = header.sub('h2>', 
      "a href=#{page(this).inspect} class='next_link'>")
    prev_link[after] = header.sub('h2>', 
      "a href=#{page(this).inspect} class='prev_link'>")
  end

  # adjust todo links
  env.gsub! /<li>.*?<\/li>/m do |li|
    section = li.scan(/href="#(section-.*?)"/).flatten.first
    li.gsub('href="#', "href=\"#{section}.html#").gsub("##{section}\"", '"')
  end

  # output the files
  system "rm -rf #{WORK}/checkdepot"
  system "mkdir -p #{WORK}/checkdepot"
  Dir.chdir "#{WORK}/checkdepot" do
    open('depot.css','w') {|file| file.write(style)}
    toc.gsub! /<a href="#(section-[\d\.]+)"/, '<a href="\1.html"'
    open('index.html','w') {|file| file.write(head+toc+env+tail)}
    head.sub! /(<h1.*h1>)/, '<a href="index.html">\1</a>'
    Hash[*sections].each do |section, body|
      links = "      #{next_link[section]}\n      #{prev_link[section]}\n"
      links = "    <p>\n#{links}    </p>\n"
      body = links + '    <a class="toc">'+ body + links
      open(page(section),'w') {|file| file.write(head+body+tail)}
    end
  end
else
  open(File.join(WORK, 'status'), 'w') {|file| file.puts 'NO OUTPUT'}
end

# copy the log
system "mkdir -p #{WORK}/checkdepot"
system "cp #{LOG} #{WORK}/checkdepot/makedepot.log"

# restore rails to master
Dir.chdir($rails) do
  system 'git checkout master' unless BRANCH=='master'
end

libs.each do |lib, branch|
  if branch != 'master'
    Dir.chdir(File.join(HOME,'git',lib)) do
      print lib + ': '
      system 'git checkout master'
    end
  end
end

exit status.exitstatus
