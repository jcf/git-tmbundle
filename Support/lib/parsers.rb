# encoding: utf-8
require File.dirname(__FILE__) + "/stream_progress_methods.rb"

module Parsers
  def parse_status(input)
    base_dir = path
    file_statuses = {}

    parse_status_hash(input).each do |file, status|
      file_statuses[expand_path_preserving_trailing_slash(file, base_dir)] = status
    end

    sorted_results = file_statuses.sort.map do |file_path, display_status|
      {:path => file_path, :display => shorten(file_path, base_dir), :status => Git::GIT_SCM_STATUS_MAP[display_status]}
    end
  end

  def parse_status_hash(input)
    output = []
    file_statuses = {}
    state = nil
    input.split("\n").each do |line|
      case line
      when /^# Changes to be committed:/
        state = :added
      when /^# Changed but not updated:/
        state = :modified
      when /^# Untracked files:/
        state = :untracked
      when /^#\t(([a-z ]+): +){0,1}(.*?)(?: \([a-z ]+\))?$/
        filename = $3
        status_description = $2
        status = case status_description
        when "new file"
          state == :added ? "A" : "?"
        when "renamed"
          filename = filename.split(/ +\-> +/).last
          "R"
        when "deleted"
          "D"
        when "modified"
          "M"
        when "unmerged", 'both modified'
          # do a quick check to see if the merge is resolved
          if File.directory?(path_for(filename)) # it's a submodule
            "G"
          else
            file_has_conflict_markers(path_for(filename)) ? "C" : "G"
          end
        else
          "?"
        end
        filename = $1.gsub(/(\\\d{3})+/) { $&.scan(/\d{3}/).map { |str| str.oct }.pack("c*") } if filename =~ /^"(.*)"$/
        file_statuses[filename] ||= status
      end

    end
    file_statuses
  end

  def file_has_conflict_markers(filename)
    file_contents = File.exist?(filename) ? File.read(filename) : ""
    if /^={7}$/.match(file_contents) && /^\<{7} /.match(file_contents) && /^>{7} /.match(file_contents)
      true
    else
      false
    end
  end

  def parse_commit(commit_output)
    result = {:output => ""}
    commit_output.split("\n").each do |line|
      case line
      # Git <1.6.1: Created commit 9bd94be: commit msg
      when /^ *Created commit ([a-f0-9]+): (.*)$/
        result[:rev] = $1
        result[:message] = $2
      # Git 1.6.1: [master]: created 9bd94be: "commit msg"
      when /^ *\[.+?\]: created ([a-f0-9]+): "(.*)"$/
        result[:rev] = $1
        result[:message] = $2
      # Git >1.6.1: [master 9bd94be] commit msg
      when /^ *\[\S+ ([a-f0-9]+)\] (.*)$/
        result[:rev] = $1
        result[:message] = $2
      when /^ *([0-9]+) files changed, ([0-9]+) insertions\(\+\), ([0-9]+) deletions\(\-\) *$/
        result[:files_changed] = $1.to_i
        result[:insertions] = $2.to_i
        result[:deletions] = $3.to_i
      else
        result[:output] << "#{line}\n"
      end
    end
    result
  end

  def parse_annotation(input)
    require 'time.rb'
    require 'date.rb'

    output = []
    match_item = /([^\t]+)\t/
    match_last_item = /([^\)]+)\)/
    input.split("\n").each do |line|
      if /#{match_item}\(#{match_item}#{match_item}#{match_last_item}(.*)$/i.match(line)
        rev,author,date,ln,text = $1,$2,$3,$4,$5
        nc = /^0+$/.match(rev)
        output << {
          :rev => nc ? "-current-" : rev,
          :author => nc ? "-none-" : author.strip,
          :date => nc ? "-pending-" : Time.parse(date),
          :ln => ln.to_i,
          :text => text
        }
      else
        raise "didnt recognize line #{line}"
      end
    end
    output
  end

  def parse_merge(input)
    output = {:text => "", :conflicts => []}
    input.split("\n").each do |line|
      case line
      when /^CONFLICT \(.+?\): Merge conflict in (.+)/
        output[:conflicts] << $1
      when /^CONFLICT \(delete\/modify\): (.+) deleted in /
        output[:conflicts] << $1
      end
      output[:text] << "#{line}\n"
    end
    output
  end

  def parse_log(log_content)
    output = []
    current = nil
    log_blocks = log_content.split("\n\n")
    log_blocks.each do |block|
      case block.split("\n").first
      when /^commit /
        output << (current = {})
        data = block.scan(/^([a-z]+):? (.*)$/i).inject({}) { |h, v| h[v.first] = v.last;  h }
        current.merge!(
          :rev => data["commit"],
          :author => data["Author"],
          :date => Time.parse(data["Date"])
        )
      when / {4}(.*)/
        current[:msg] = block.gsub(/^ {4}/, "")
      when /^diff /
        current[:diff] = parse_diff(block)
      end
    end
    output
  end

  def parse_diff_check(diff_content)
    output = []
    current = nil
    # puts "<pre>#{htmlize(diff_content)}</pre>"
    diff_content.split("\n").each do |line|
      case line
      when /^([\w\/\.]+):(\d+):\s*(.+)$/
        current = {}
        current[:file_path] = $1
        current[:file_line] = $2
        current[:warning] = $3
        current[:lines] = []
        output << current
      when /^\+(.*)$/ # insertion
        current[:lines] << {:type => :insertion, :text => $1 }
      when /^\-(.*)$/ # deletion
        current[:lines] << {:type => :deletion, :text => $1 }
      end
    end
    output
  end

  def parse_diff(diff_content)
    output = []
    current = nil
    ln_left, ln_right = 0,0
    # puts "<pre>#{htmlize(diff_content)}</pre>"
    diff_content.split("\n").each do |line|
      case line
      when /^diff \-\-git/
        current = {:left => {}, :right => {}, :lines => []}
      when /^(deleted|new) file mode (\d{6})$/
        current[:status] = $1.to_sym
        current[:mode] = $2
      when /^index (([a-f0-9]+)..([a-f0-9]+)){0,1}( (\d{6}))?/i
        current[:left][:index] = $2
        current[:right][:index] = $3
        current[:mode] ||= $5
        current[:status] ||= :modified
        output << current
        /([0-9a-f]+)\.\.([0-9a-f]+) ([0-9]+)/i.match($1)
        current[:index_start] = $1
        current[:index_end] = $2
        current[:index_mode] = $3
      when /^\-\-\- ([ab]\/){0,1}(.+?)(\t*)$/
        current[:left][:file_path] = $2 unless $2 == "/dev/null"
      when /^\+\+\+ ([ab]\/){0,1}(.+?)(\t*)$/
        current[:right][:file_path] = $2 unless $2 == "/dev/null"
      when /^@@ \-(\d+)(,(\d+)){0,1} \+(\d+)(,(\d+)){0,1} @@ {0,1}(.*)$/  # @@ -5,6 +5,25 @@ class SCM::Git::Diff
        ln_left = $1.to_i
        ln_left_count = $3.to_i
        ln_right = $4.to_i
        ln_right_count = $6.to_i
        current[:left][:ln_start] ||= ln_left
        current[:right][:ln_start] ||= ln_right
        current[:left][:ln_end] = ln_left + ln_left_count
        current[:right][:ln_end] = ln_right + ln_right_count
        current[:first_line] = $5
        current[:lines] << {:type => :cut, :ln_left => "…", :ln_right => "…", :text => "" } unless current[:lines].empty?
      when /^\+(.*)$/ # insertion
        current[:lines] << {:type => :insertion, :ln_left => nil, :ln_right => ln_right, :text => $1 }
        ln_right += 1
      when /^\-(.*)$/ # deletion
        current[:lines] << {:type => :deletion, :ln_left => ln_left, :ln_right => nil, :text => $1 }
        ln_left += 1
      when /^ (.*)$/
        current[:lines] << {:ln_left => ln_left, :ln_right => ln_right, :text => $1 }
        ln_left += 1
        ln_right += 1
      when /^\\ (No newline at end of file)/
        last_line = current[:lines].last
        current[:lines] << {
          :type => :eof,
          :ln_left => (last_line[:ln_left] && "EOF"),
          :ln_right => (last_line[:ln_right] && "EOF"),
          :text => $1}
      end
    end
    output
  end
  def process_push(stream, callbacks = {})
    output = {:pushes => {}, :text => "", :nothing_to_push => false}
    branch = nil

    process_with_progress(stream, :callbacks => callbacks, :start_regexp => /(?-:remote: )?(Deltifying|Writing) ([0-9]+) objects/) do |line|
      case line
      when /(?-:remote: )?^Everything up\-to\-date/
        output[:nothing_to_push] = true
      when /(?-:remote: )?^(.+): ([a-f0-9]{40}) \-\> ([a-f0-9]{40})/
        output[:pushes][$1] = [$2,$3] unless version_1_5_4?
      when /^ +([0-9a-f]+\.\.[0-9a-f]+) +([^ ]+) +\-\> (.+)$/
        output[:pushes][$2] = get_rev_range($1)

      else
        output[:text] << line
      end

    end
    output
  end

  def process_pull(stream, callbacks = {})
    output = {:pulls => {}, :text => "", :nothing_to_pull => false}
    branch = nil
    branch = self.branch.current_name
    process_with_progress(stream, :callbacks => callbacks, :start_regexp => /(?-:remote: )?(Unpacking) ([0-9]+) objects/) do |line|
      case line
      when /^Already up\-to\-date/
        output[:nothing_to_pull] = true
      when /^\* ([^:]+):/
        branch = $1
      when /^([a-z]+) ([0-9a-f]+\.\.[0-9a-f]+)/i # 1.5.3 format
        output[:pulls][branch] = get_rev_range($2)
      when /^  (old\.\.new|commit): (.+)/         # 1.5.3 format
        output[:pulls][branch] = get_rev_range($2)
      when /^ +([0-9a-f]+\.\.[0-9a-f]+) +([^ ]+) +\-\> (.+)$/
        output[:pulls][$2] = get_rev_range($1)
      end

      output[:text] << line
    end
    output
  end

  def process_fetch(stream, callbacks = {})
    output = {:fetches => {}, :text => ""}
    process_with_progress(stream, :callbacks => callbacks, :start_regexp => /(?-:remote: )?(Compressing) ([0-9]+) objects/) do |line|
      case line
      when /^\* ([^:]+):/
        branch = $1
      # when /^([a-z]+) ([0-9a-f]+\.\.[0-9a-f]+)/i
      #   output[:pulls][branch] = get_rev_range($2)
      # when /^  (old\.\.new|commit): (.+)/
      #   output[:pulls][branch] = get_rev_range($2)
      when /^ +([0-9a-f]+\.\.[0-9a-f]+) +([^ ]+) +\-\> (.+)$/
        output[:fetches][$2] = get_rev_range($1)
      end

      output[:text] << line
    end
    output
  end

  include StreamProgressMethods
  extend self
end