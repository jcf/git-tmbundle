# encoding: utf-8

class DiffController < ApplicationController
  include SubmoduleHelper
  include DiffHelper
  def diff
    show_diff_title unless params[:layout].to_s=="false"
    @rev = params[:rev]
    @title = params[:title] || "Diff result"
    params[:context_lines] = git.config.context_lines if git.config.context_lines
    
    render("_diff_results", :locals => {
      :diff_check_results => git.config.show_diff_check? ? git.with_path(params[:git_path]).diff_check(params.filter(:path, :revision, :context_lines, :revisions, :branches, :tags, :since)) : [],
      :diff_results => git.with_path(params[:git_path]).diff(params.filter(:path, :revision, :context_lines, :revisions, :branches, :tags, :since)),
      :git => git.with_path(params[:git_path])
    })
  end
  
  def uncommitted_changes
    paths = case
      when params[:path] 
        [params[:path]]
      else
        git.paths
      end
    base = git.path
    open_in_tm_link
    puts "<h2>Uncommitted Changes for ‘#{htmlize(paths.map{|path| shorten(path, base)} * ', ')}’ on branch ‘#{git.branch.current_name}’</h2>"
    
    paths.each do |path|
      render("_diff_results", :locals => {
        :diff_check_results => git.config.show_diff_check? ? git.diff_check(:path => path, :since => "HEAD") : [],
        :diff_results => git.diff(:path => path, :since => "HEAD")
      })
      
      git.submodule.all(:path => path).each do |submodule|
        next if (diff_results = submodule.git.diff(:since => "HEAD")).blank?
        render_submodule_header(submodule)
        render("_diff_results", :locals => {:git => submodule.git, :diff_results => diff_results, :diff_check_results => git.config.show_diff_check? ? git.diff_check(:path => path, :since => "HEAD") : []})
      end
    end
  end
  
  def compare_revisions
    file_paths = git.paths
    if file_paths.length > 1
      base = git.nca(file_paths)
    else 
      base = file_paths.first
    end
    
    log = LogController.new
    revisions = log.choose_revision(base, "Choose revisions for #{file_paths.map{|f| git.make_local_path(f)}.join(',')}", :multiple, :sort => true)

    if revisions.nil?
      puts "Canceled"
      return
    end
    
    render_component(:controller => "diff", :action => "diff", :revisions => revisions, :path => base)
  end
  
protected
  def open_in_tm_link
    File.unlink('/tmp/output.diff') if File.exist? '/tmp/output.diff'
    puts <<-EOF
      <a style='float:right' href='txmt://open?url=file://#{e_url '/tmp/output.diff'}'>Open diff in TextMate</a>
    EOF
  end
  
  def show_diff_title
    puts "<h2>"
    case
    when params[:branches]
      branches = params[:branches]
      branches = branches.split("..") if params[:branches].is_a?(String)
      puts "Comparing branches #{branches.first}..#{branches.last}"
    when params[:revisions]
      revisions = params[:revisions]
      revisions = revisions.split("..") if params[:revisions].is_a?(String)
      puts "Comparing branches #{revisions.first}..#{revisions.last}"
    end
    puts "</h2>"
  end
  
  def extract_diff_params(params)
    diff_params = params.dup.delete_if do |key, value|
      ! [:revisions, :revision, :branches, :tags, :path].include?(key)
    end
    diff_params[:context_lines] = git.config["git-tmbundle.log.context-lines"] if git.config["git-tmbundle.log.context-lines"]
    diff_params
  end
end
