module VCSToolkit

  class Repository
    attr_reader :object_store, :staging_area,
                :commit_class, :tree_class, :blob_class, :label_class

    attr_accessor :head, :branch_head

    def initialize(object_store, staging_area, head:         nil,
                                               commit_class: Objects::Commit,
                                               tree_class:   Objects::Tree,
                                               blob_class:   Objects::Blob,
                                               label_class:  Objects::Label)
      @object_store = object_store
      @staging_area = staging_area

      @commit_class = commit_class
      @tree_class   = tree_class
      @blob_class   = blob_class
      @label_class  = label_class

      self.head = head if head
    end

    def head=(label_or_id)
      case label_or_id
      when Objects::Label
        @head = label_or_id.id
      when String
        @head = label_or_id
      when nil
        # Ignore. There is no current branch
      else
        raise UnknownLabelError
      end

      @branch_head = get_object(@head).reference_id
      set_label :head, @head
    end

    def branch_head=(commit_or_id)
      case commit_or_id
      when Objects::Commit
        @branch_head = commit_or_id.id
      when String
        @branch_head = commit_or_id
      when nil
        # Ignore. The current branch has no commits
      else
        raise UnknownLabelError
      end

      set_label head, @branch_head if head
    end

    def commit(message, author, date, ignores: [], parents: nil, **context)
      tree = create_tree ignores: ignores, **context

      parents = branch_head.nil? ? [] : [branch_head] if parents.nil?

      commit = commit_class.new message: message,
                                tree:    tree.id,
                                parents: parents,
                                author:  author,
                                date:    date,
                                **context

      object_store.store commit.id, commit
      self.branch_head = commit

      commit
    end

    ##
    # Return the object with this object_id or nil if it doesn't exist.
    #
    def get_object(object_id)
      object_store.fetch object_id if object_store.key? object_id
    end

    alias_method :[], :get_object

    ##
    # Return new, changed and deleted files
    # compared to a specific commit and the staging area.
    #
    # The return value is a hash with :created, :changed and :deleted keys.
    #
    def status(commit, ignore: [])
      tree = get_object(commit.tree) unless commit.nil?

      Utils::Status.compare_tree_and_store tree,
                                           staging_area,
                                           object_store,
                                           ignore: ignore
    end

    ##
    # Return new, changed and deleted files
    # by comparing two commits.
    #
    # The return value is a hash with :created, :changed and :deleted keys.
    #
    def commit_status(base_commit, new_commit, ignore: [])
      base_tree = get_object(base_commit.tree) unless base_commit.nil?
      new_tree  = get_object(new_commit.tree)  unless new_commit.nil?

      Utils::Status.compare_trees base_tree,
                                  new_tree,
                                  object_store,
                                  ignore: ignore
    end

    ##
    # Enumerate all commits beginning with branch_head and ending
    # with the commits that have empty `parents` list.
    #
    # They aren't strictly ordered by date, but in a BFS visit order.
    #
    def history
      return [] if branch_head.nil?

      get_object(branch_head).history(object_store)
    end

    ##
    # Merge two commits and save the changes to the staging area.
    #
    def merge(commit_one, commit_two)
      common_ancestor  = commit_one.common_ancestor(commit_two, object_store)
      commit_one_files = Hash[get_object(commit_one.tree).all_files(object_store).to_a]
      commit_two_files = Hash[get_object(commit_two.tree).all_files(object_store).to_a]

      if common_ancestor.nil?
        ancestor_files = {}
      else
        ancestor_files = Hash[get_object(common_ancestor.tree).all_files(object_store).to_a]
      end

      all_files = commit_one_files.keys | commit_two_files.keys | ancestor_files.keys

      merged     = []
      conflicted = []

      all_files.each do |file|
        ancestor = ancestor_files.key?(file)   ? get_object(ancestor_files[file]).content.lines   : []
        file_one = commit_one_files.key?(file) ? get_object(commit_one_files[file]).content.lines : []
        file_two = commit_two_files.key?(file) ? get_object(commit_two_files[file]).content.lines : []

        diff = VCSToolkit::Merge.three_way ancestor, file_one, file_two

        if diff.has_conflicts?
          conflicted << file
        elsif diff.has_changes?
          merged << file
        end

        content = diff.new_content("<<<<< #{commit_one.id}\n", ">>>>> #{commit_two.id}\n", "=====\n")

        if content.empty?
          staging_area.delete_file file if staging_area.file? file
        else
          staging_area.store file, content.join('')
        end
      end

      {merged: merged, conflicted: conflicted}
    end

    ##
    # Return a list of changes between a file in the staging area
    # and a specific commit.
    #
    # This method is just a tiny wrapper around VCSToolkit::Diff.from_sequences
    # which loads the two files and splits them by lines beforehand.
    # It also ensures that both files have \n at the end (otherwise the last
    # two lines of the diff may be merged).
    #
    def file_difference(file_path, commit)
      if staging_area.file? file_path
        file_lines = staging_area.fetch(file_path).lines
        file_lines.last << "\n" unless file_lines.last.nil? or file_lines.last.end_with? "\n"
      else
        file_lines = []
      end

      tree   = get_object commit.tree

      blob_name_and_id = tree.all_files(object_store).find { |file, _| file_path == file }

      if blob_name_and_id.nil?
        blob_lines = []
      else
        blob       = get_object blob_name_and_id.last
        blob_lines = blob.content.lines
        blob_lines.last << "\n" unless blob_lines.last.nil? or blob_lines.last.end_with? "\n"
      end

      Diff.from_sequences blob_lines, file_lines
    end

    def restore(path='', commit)
      tree       = get_object commit.tree
      object_id  = tree.find(object_store, path)

      raise KeyError, 'File does not exist in the specified commit' if object_id.nil?

      blob_or_tree = get_object object_id

      case blob_or_tree.object_type
      when :blob
        restore_file path, blob_or_tree
      when :tree
        restore_directory path, blob_or_tree
      else
        raise 'Unknown object type returned by Tree#find'
      end
    end

    ##
    # Create a label (named object) pointing to `reference_id`
    #
    # If the label already exists it is overriden.
    #
    def set_label(name, reference_id)
      label = label_class.new id: name, reference_id: reference_id

      object_store.store name, label
    end

    private

    def restore_directory(path, tree)
      tree.all_files(object_store).each do |file, blob_id|
        restore_file File.join(path, file), get_object(blob_id)
      end
    end

    def restore_file(path, blob)
      staging_area.store path, blob.content
    end

    protected

    def create_tree(path='', ignore: [/^\./], **context)
      files = staging_area.files(path, ignore: ignore).each_with_object({}) do |file_name, files|
        file_path = concat_path path, file_name

        next if ignored? file_path, ignore

        files[file_name] = blob_class.new content: staging_area.fetch(file_path), **context
      end

      trees = staging_area.directories(path, ignore: ignore).each_with_object({}) do |dir_name, trees|
        dir_path = concat_path path, dir_name

        next if ignored? dir_path, ignore

        trees[dir_name] = create_tree dir_path, **context
      end

      files.each do |name, file|
        object_store.store file.id, file unless object_store.key? file.id

        files[name] = file.id
      end
      trees.each do |name, tree|
        trees[name] = tree.id
      end

      tree = tree_class.new files: files,
                            trees: trees,
                            **context

      object_store.store tree.id, tree unless object_store.key? tree.id

      tree
    end

    private

    def ignored?(path, ignores)
      ignores.any? do |ignore|
        if ignore.is_a? Regexp
          ignore =~ path
        else
          ignore == path
        end
      end
    end

    def concat_path(directory, file)
      return file if directory.empty?

      file      = file.sub(/^\/+/, '')
      directory = directory.sub(/\/+$/, '')

      "#{directory}/#{file}"
    end
  end

end