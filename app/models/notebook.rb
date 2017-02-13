# Notebook model
class Notebook < ActiveRecord::Base
  belongs_to :owner, polymorphic: true
  belongs_to :creator, class_name: 'User'
  belongs_to :updater, class_name: 'User'
  has_one :notebook_summary, dependent: :destroy
  has_many :change_requests, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :clicks, dependent: :destroy
  has_many :notebook_similarities, dependent: :destroy
  has_many :keywords, dependent: :destroy
  has_many :feedbacks, dependent: :destroy
  has_and_belongs_to_many :shares, class_name: 'User', join_table: 'shares'
  has_and_belongs_to_many :stars, class_name: 'User', join_table: 'stars'
  has_many :code_cells, dependent: :destroy
  has_many :executions, through: :code_cells

  validates :uuid, :title, :description, :owner, presence: true
  validates :public, not_nil: true
  validates :uuid, uniqueness: { case_sensitive: false }
  validates :uuid, uuid: true

  after_destroy :remove_content, :remove_wordcloud

  searchable do # rubocop: disable Metrics/BlockLength
    # For permissions...
    boolean :public
    string :owner_type
    integer :owner_id
    integer :shares, multiple: true do
      shares.pluck(:id)
    end

    # For sorting...
    time :updated_at
    time :created_at
    string :title do
      Notebook.groom(title).downcase
    end
    # Note: tried to join to NotebookSummary for these, but sorting didn't work
    integer :views do
      num_views
    end
    integer :stars do
      num_stars
    end
    integer :runs do
      num_runs
    end
    float :health

    # For searching...
    integer :id
    text :lang
    text :title, boost: 50.0, stored: true do
      Notebook.groom(title)
    end
    text :body, stored: true do
      notebook.text rescue ''
    end
    text :tags do
      tags.pluck(:tag)
    end
    text :description, boost: 10.0, stored: true
    text :owner do
      owner.is_a?(User) ? owner.user_name : owner.name
    end
    text :owner_description do
      owner.is_a?(User) ? owner.name : owner.description
    end
  end

  # Sets the max number of notebooks per page for pagination
  self.per_page = 20

  attr_accessor :fulltext_snippet
  attr_accessor :fulltext_score
  attr_accessor :fulltext_reasons

  extend Forwardable

  # Exception for uploads with bad parameters
  class BadUpload < RuntimeError
    attr_reader :errors

    def initialize(message, errors=nil)
      super(message)
      @errors = errors
    end

    def message
      msg = super
      if errors
        msg + ': ' + errors.full_messages.join('; ')
      else
        msg
      end
    end
  end

  # Constructor
  def initialize(*args, &block)
    super(*args, &block)
    # Go ahead and create a default summary
    self.notebook_summary = NotebookSummary.new(
      views: 1,
      unique_views: 1
    )
    self.content_updated_at = Time.current
  end


  #########################################################
  # Extension points
  #########################################################

  include ExtendableModel

  # rubocop: disable Lint/UnusedMethodArgument

  # Cleans up a string for display
  def self.groom(str)
    str
  end

  # Custom permissions for notebook read
  def self.custom_permissions_read(notebook, user, use_admin=false)
    true
  end

  # Custom permissions for notebook edit
  def self.custom_permissions_edit(notebook, user, use_admin=false)
    true
  end

  # Custom permission checking for mysql query
  def self.custom_permissions_sql(relation, user, use_admin=false)
    relation
  end

  # Custom permission checking for solr fulltext query
  def self.custom_permissions_solr(user)
    proc do
    end
  end

  # rubocop: enable Lint/UnusedMethodArgument

  #########################################################
  # Database helpers
  #########################################################

  # Helper function to join things with a permissions clause
  def self.readable_join(thing, user, use_admin=false)
    relation =
      if user.member?
        thing
          .joins("LEFT OUTER JOIN shares ON (shares.notebook_id = notebooks.id AND shares.user_id = #{user.id})")
          .where(
            '(public = 1) OR ' \
            "(owner_type = 'User' AND owner_id = ?) OR " \
            "(owner_type = 'Group' AND owner_id IN (?)) OR " \
            '(shares.user_id = ?) OR ' \
            '(?)',
            user.id,
            user.groups.map(&:id),
            user.id,
            (use_admin && user.admin?)
          )
      else
        thing.where('(public = 1)')
      end
    custom_permissions_sql(relation, user, use_admin)
  end

  # Scope that returns all notebooks readable by the given user
  def self.readable_by(user, use_admin=false)
    readable_join(Notebook, user, use_admin)
  end

  # Readable joined with summary + suggestions.
  # This is used so we can sort by notebook fields as well as
  # suggestion score, num views/stars/runs.
  def self.readable_megajoin(user, use_admin=false)
    relation = readable_by(user, use_admin)
      .joins('JOIN notebook_summaries ON (notebook_summaries.notebook_id = notebooks.id)')

    prefix = 'LEFT OUTER JOIN suggested_notebooks ON (suggested_notebooks.notebook_id = notebooks.id'
    relation =
      if user.member?
        relation.joins(prefix + " AND suggested_notebooks.user_id = #{user.id})")
      else
        relation.joins(prefix + ' AND suggested_notebooks.user_id IS NULL)')
      end

    relation
      .select([
        'notebooks.*',
        'views',
        'stars',
        'runs',
        SuggestedNotebook.reasons_sql,
        SuggestedNotebook.score_sql
      ].join(', '))
      .group('notebooks.id')
  end

  # Helper function to join things with a permissions clause
  def self.editable_join(thing, user, use_admin=false)
    relation = thing
      .joins("LEFT OUTER JOIN shares ON (shares.notebook_id = notebooks.id AND shares.user_id = #{user.id})")
      .where(
        "(owner_type = 'User' AND owner_id = ?) OR " \
        "(owner_type = 'Group' AND owner_id IN (?)) OR " \
        '(shares.user_id = ?) OR ' \
        '(?)',
        user.id,
        user.groups_editor.map(&:id),
        user.id,
        (use_admin && user.admin?)
      )
    custom_permissions_sql(relation, user, use_admin)
  end

  # Scope that returns all notebooks editable by the given user
  def self.editable_by(user, use_admin=false)
    editable_join(Notebook, user, use_admin)
  end

  # Language => count for the given user
  def self.language_counts(user)
    languages = Notebook.readable_by(user).group(:lang).count.map {|k, v| [k, nil, v]}
    python2 = Notebook.readable_by(user).where(lang: 'python').where("lang_version LIKE '2.%'").count
    python3 = Notebook.readable_by(user).where(lang: 'python').where("lang_version LIKE '3.%'").count
    languages += [['python', '2', python2], ['python', '3', python3]]
    languages.sort_by {|lang, _version, _count| lang.downcase}
  end

  # Get user's suggested notebooks to boost fulltext score
  def self.user_suggestions(user)
    user.suggested_notebooks
      .where("reason NOT LIKE 'randomly%'")
      .select(
        [
          'notebook_id',
          SuggestedNotebook.reasons_sql,
          SuggestedNotebook.score_sql
        ].join(', ')
      )
      .group(:notebook_id)
      .map {|row| [row.notebook_id, { reasons: row.reasons, score: row.score }]}
      .to_h
  end

  # Get healthy notebooks to boost fulltext score
  def self.healthy_notebooks
    Notebook
      .joins('JOIN notebook_summaries ON (notebook_summaries.notebook_id = notebooks.id)')
      .where('health > 0.5')
      .map {|nb| [nb.id, nb.health]}
      .to_h
  end

  # Full-text search scoped by readability
  def self.fulltext_search(text, user, opts={})
    page = opts[:page] || 1
    sort = opts[:sort] || :score
    sort_dir = opts[:sort_dir] || :desc
    use_admin = opts[:use_admin].nil? ? false : opts[:use_admin]

    suggested = user_suggestions(user)
    sunspot = Notebook.search do
      fulltext(text, highlight: true) do
        suggested.each {|id, info| boost(info[:score] * 5.0) {with(:id, id)}}
        healthy_notebooks.each {|id, score| boost(score * 10.0) {with(:id, id)}}
      end
      unless use_admin
        all_of do
          any_of do
            with(:public, true)
            with(:shares, user.id)
            all_of do
              with(:owner_type, 'User')
              with(:owner_id, user.id)
            end
            all_of do
              with(:owner_type, 'Group')
              with(:owner_id, user.groups.pluck(:id))
            end
          end
          instance_eval(&Notebook.custom_permissions_solr(user))
        end
      end
      order_by sort, sort_dir
      paginate page: page, per_page: per_page
    end
    sunspot.hits.each do |hit|
      hit.result.fulltext_snippet = hit.highlights.map(&:format).join(' ... ')
      hit.result.fulltext_snippet += " [score: #{format('%.4f', hit.score)}]" if user.admin? && hit.score
      hit.result.fulltext_score = hit.score
      hit.result.fulltext_reasons = suggested[hit.result.id][:reasons] if suggested.include?(hit.result.id)
    end
    sunspot.results
  end

  def self.get(user, opts={})
    if opts[:q]
      includes(:creator, :updater, :owner, :tags)
        .fulltext_search(opts[:q], user, opts)
    else
      page = opts[:page] || 1
      sort = opts[:sort] || :score
      sort_dir = opts[:sort_dir] || :desc
      use_admin = opts[:use_admin].nil? ? false : opts[:use_admin]

      order =
        if %i(stars views runs score health).include?(sort)
          "#{sort} #{sort_dir.upcase}"
        else
          "notebooks.#{sort} #{sort_dir.upcase}"
        end

      readable_megajoin(user, use_admin)
        .includes(:creator, :updater, :owner, :tags)
        .order(order)
        .paginate(page: page)
    end
  end

  # Notebooks similar to this one, filtered by permissions
  def similar_for(user, use_admin=false)
    similar = notebook_similarities
      .includes(:other_notebook)
      .joins('JOIN notebooks ON notebooks.id = notebook_similarities.other_notebook_id')
    Notebook.readable_join(similar, user, use_admin).order(score: :desc)
  end

  # Escape the highlight snippet returned by Solr
  def escape_highlight(s)
    return s if s.blank?
    # Escape HTML but then unescape tags added by Solr
    CGI.escapeHTML(s)
      .gsub('&lt;b&gt;', '<b>')
      .gsub('&lt;/b&gt;', '</b>')
      .gsub('&lt;i&gt;', '<i>')
      .gsub('&lt;/i&gt;', '</i>')
      .gsub('&lt;em&gt;', '<em>')
      .gsub('&lt;/em&gt;', '</em>')
      .gsub('&lt;br&gt;', '<br>')
  end

  # Snippet from fulltext and/or suggestions
  def snippet
    fulltext = escape_highlight(fulltext_snippet)
    suggestion =
      if fulltext_reasons
        "<em>#{fulltext_reasons.capitalize}</em>"
      elsif respond_to?(:reasons) && reasons
        "<em>#{reasons.capitalize}</em>"
      end
    if fulltext && suggestion
      "#{fulltext}<br><br>#{suggestion}"
    elsif fulltext
      fulltext
    elsif suggestion
      suggestion
    end
  end

  # Helper for custom read permissions
  def custom_read_check(user, use_admin=false)
    Notebook.custom_permissions_read(self, user, use_admin)
  end

  # Helper for custom edit permissions
  def custom_edit_check(user, use_admin=false)
    Notebook.custom_permissions_edit(self, user, use_admin)
  end


  #########################################################
  # Raw content methods
  #########################################################

  # Location on disk
  def basename
    "#{uuid}.ipynb"
  end

  # Location on disk
  def filename
    File.join(GalleryConfig.directories.cache, basename)
  end

  # The raw content from the file cache
  def content
    File.read(filename, encoding: 'UTF-8') if File.exist?(filename)
  end

  # The JSON-parsed notebook from the file cache
  def notebook
    JupyterNotebook.new(content)
  end

  # Set new content in file cache and repo
  def content=(content)
    # Save to cache and update hashes
    File.write(filename, content)
    rehash

    # Update modified time in database
    self.content_updated_at = Time.current
  end

  # Save new version of notebook
  def notebook=(notebook_obj)
    self.content = notebook_obj.to_json
  end

  # Remove the cached file
  def remove_content
    File.unlink(filename) if File.exist?(filename)
  end


  #########################################################
  # Wordcloud methods
  #########################################################

  # Location on disk
  def wordcloud_image_file
    File.join(GalleryConfig.directories.wordclouds, "#{uuid}.png")
  end

  # Location on disk
  def wordcloud_map_file
    File.join(GalleryConfig.directories.wordclouds, "#{uuid}.map")
  end

  # Has the wordcloud been generated?
  def wordcloud_exists?
    File.exist?(wordcloud_image_file) && File.exist?(wordcloud_map_file)
  end

  # The raw image map from the file cache
  def wordcloud_map
    File.read(wordcloud_map_file) if File.exist?(wordcloud_map_file)
  end

  # Generate the wordcloud image and map
  def generate_wordcloud
    # Generating the cloud is slow, so only do it if the content
    # has changed OR we haven't regenerated it recently. (The top
    # keywords in theory could change as the whole corpus changes,
    # so we still want to occasionally regenerate the cloud.)
    need_to_regenerate =
      !File.exist?(wordcloud_image_file) ||
      File.mtime(wordcloud_image_file) < 7.days.ago ||
      File.mtime(wordcloud_image_file) < content_updated_at
    return unless need_to_regenerate
    make_wordcloud(
      keywords.pluck(:keyword, :tfidf),
      uuid,
      "/notebooks/#{uuid}/wordcloud.png",
      '/notebooks?q=%s&sort=score',
      width: 320,
      height: 200,
      noise: false
    )
  end

  # Remove the files
  def remove_wordcloud
    [wordcloud_image_file, wordcloud_map_file].each do |file|
      File.unlink(file) if File.exist?(file)
    end
  end

  # Generate all wordclouds
  def self.generate_all_wordclouds
    Notebook.find_each(&:generate_wordcloud)
  end


  #########################################################
  # Tag methods
  #########################################################

  # Add a tag (applied by user) to this notebook
  def add_tag(tag, user=nil)
    return unless tags.where(tag: tag).empty?
    tag = Tag.new(tag: tag, user: user, notebook: self)
    tags.push(tag) if tag.valid?
  end

  # Remove a tag from this notebook
  def remove_tag(tag)
    tags.where(tag: tag).destroy_all
  end

  # Set tags to the specified list
  def set_tags(tag_list, user=nil)
    tags.destroy_all
    tag_list.each {|tag| add_tag(tag, user)}
  end

  # Is notebook trusted?
  def trusted?
    !tags.where(tag: 'trusted').empty?
  end


  #########################################################
  # Click methods
  #########################################################

  # Delegate count methods to summary object
  NotebookSummary.attribute_names.each do |name|
    next if name == 'id' || name.end_with?('_id', '_at')
    if %w(health).include?(name)
      def_delegator :notebook_summary, name.to_sym, name.to_sym
    else
      def_delegator :notebook_summary, name.to_sym, "num_#{name}".to_sym
    end
  end

  # If for some reason the summary isn't there, create it now
  def notebook_summary
    nbsum = super
    if nbsum
      nbsum
    else
      self.notebook_summary = NotebookSummary.generate_from(self)
    end
  end

  # Update the counts in the summary object
  def update_summary
    views = 0
    viewers = 0
    downloads = 0
    downloaders = 0
    runs = 0
    runners = 0
    clicks
      .where(action: ['viewed notebook', 'downloaded notebook', 'ran notebook'])
      .group(:user_id, :action)
      .count
      .map(&:flatten)
      .each do |_user_id, action, count|
        case action
        when 'viewed notebook'
          views += count
          viewers += 1
        when 'downloaded notebook'
          downloads += count
          downloaders += 1
        when 'ran notebook'
          runs += count
          runners += 1
        end
      end

    nbsum = notebook_summary
    nbsum.views = views
    nbsum.unique_views = viewers
    nbsum.downloads = downloads
    nbsum.unique_downloads = downloaders
    nbsum.runs = runs
    nbsum.unique_runs = runners
    nbsum.stars = stars.count
    nbsum.health = compute_health

    if nbsum.changed?
      nbsum.save
      save # to reindex counts in solr
      true
    else
      false
    end
  end

  def metrics
    metrics = {}
    NotebookSummary.attribute_names.each do |name|
      next if name == 'id' || name.end_with?('_id', '_at')
      metrics[name.to_sym] = notebook_summary.send(name.to_sym)
    end
    metrics
  end

  # Enumerable list of notebook views
  def all_viewers
    clicks.where(action: 'viewed notebook')
  end

  # Map of User => num views
  def unique_viewers
    all_viewers.group(:user).count
  end

  # Enumerable list of notebook downloads
  def all_downloaders
    clicks.where(action: 'downloaded notebook')
  end

  # Map of User => num downloads
  def unique_downloaders
    all_downloaders.group(:user).count
  end

  # Enumerable list of notebook runs
  def all_runners
    clicks.where(action: 'ran notebook')
  end

  # Map of User => num runs
  def unique_runners
    all_runners.group(:user).count
  end

  # Edit history
  def edit_history
    clicks.where(action: ['created notebook', 'edited notebook']).order(:created_at)
  end


  #########################################################
  # Instrumentation
  #########################################################

  # Rehash this notebook
  def rehash
    self.code_cells = notebook.code_cells_source.each_with_index.map do |source, i|
      CodeCell.new(
        notebook: self,
        cell_number: i,
        md5: Digest::MD5.hexdigest(source),
        ssdeep: Ssdeep.from_string(source)
      )
    end
  end

  # Rehash all notebooks
  def self.rehash
    Notebook.find_each(&:rehash)
  end

  # Health score based on execution logs
  def compute_health
    num_executions = executions.count
    num_success = executions.where(success: true).count
    num_success.to_f / num_executions if num_executions.positive?
  end

  # Number of failed cells
  def failed_cells
    code_cells.select {|cell| cell.failed?(30)}.count
  end

  # More detailed health status
  def health_status
    status = {
      failed_cells: failed_cells,
      total_cells: code_cells.count,
      score: health
    }
    status[:status] =
      if status[:score].nil?
        :unknown
      elsif status[:score] > 0.75 && status[:failed_cells] < 2
        :healthy
      else
        :unhealthy
      end
    status
  end


  #########################################################
  # Misc methods
  #########################################################

  # User-friendly URL /nb/abcd1234/Partial-title-here
  def friendly_url
    GalleryLib.friendly_url('nb', uuid, Notebook.groom(title))
  end

  # User-friendly Metrics URL /nb/abcd1234/metrics/Partial-title-here
  def friendly_metrics_url
    GalleryLib.friendly_metrics_url('nb', uuid, Notebook.groom(title))
  end

  # Owner id string
  def owner_id_str
    owner.is_a?(User) ? owner.user_name : owner.gid
  end

  # Owner email
  def owner_email
    if owner.is_a?(User)
      [owner.email]
    else
      owner.editors.pluck(:email)
    end
  end

  # Counts of packages by language
  # Returns hash[language][package] = count
  def self.package_summary
    results = {}
    by_lang = find_each
      .map {|notebook| [notebook.lang, notebook.notebook.packages]}
      .group_by {|lang, _packages| lang}

    by_lang.each do |lang, entries|
      results[lang] = entries
        .map(&:last)
        .flatten
        .group_by {|package| package}
        .map {|package, packages| [package, packages.size]}
        .to_h
    end

    results
  end
end
