require 'vcs_toolkit/diff'
require 'vcs_toolkit/conflict'

module VCSToolkit
  module Merge
    extend self

    def three_way(sequence_one, sequence_two, sequence_three)
      diff_one = Diff.from_sequences(sequence_one, sequence_two)
      diff_two = Diff.from_sequences(sequence_one, sequence_three)

      combined_changes = combine_diffs diff_one, diff_two
      merge_changes = combined_changes.flat_map do |line_number, (changeset_one, changeset_two)|
        if changeset_one.all?(&:unchanged?)
          changeset_two
        elsif changeset_two.all?(&:unchanged?)
          changeset_one
        elsif same_changes(changeset_one, changeset_two)
          # TODO: Check if they can be the same but one is split in two parts
          changeset_one
        else
          extract_conflict(changeset_one, changeset_two)
        end
      end

      Diff.new merge_changes
    end

    private

    ##
    # Return common prefix and suffix of the two changesets
    # in the following format:
    #
    #  [<common_prefix_list>, Conflict(Diff, Diff), <common_suffix_list>]
    #
    def extract_conflict(changeset_one, changeset_two)
      common_start = changeset_one.zip(changeset_two).take_while do |change_one, change_two|
        same_change(change_one, change_two)
      end

      common_end = changeset_one.reverse.zip(changeset_two.reverse).take_while do |change_one, change_two|
        same_change(change_one, change_two)
      end

      common_size = common_end.size + common_start.size

      diff_one = Diff.new changeset_one.slice(common_start.size, changeset_one.size - common_size)
      diff_two = Diff.new changeset_two.slice(common_start.size, changeset_two.size - common_size)

      common_start.map(&:first) + [Conflict.new(diff_one, diff_two)] + common_end.map(&:first)
    end

    def same_changes(changeset_one, changeset_two)
      changeset_one.size == changeset_two.size and
      changeset_one.zip(changeset_two).all? do |change_one, change_two|
        same_change(change_one, change_two)
      end
    end

    def same_change(change_one, change_two)
      # new_position is not compared deliberately
      # because any additions on a file will increase new_position
      # and because of that it will cause conflicts even
      # if the changes are the same
      change_one.action       == change_two.action       and
      change_one.old_position == change_two.old_position and
      change_one.old_element  == change_two.old_element  and
      change_one.new_element  == change_two.new_element
    end

    ##
    # Group changes by their old index.
    #
    # The structure is as follows:
    #
    #   {
    #     <line_number_on_ancestor> => [
    #       [ <change>, ... ], # The changes in the first file
    #       [ <change>, ... ]  # The changes in the second file
    #     ]
    #   }
    def combine_diffs(diff_one, diff_two)
      Hash.new { |hash, key| hash[key] = [[], []] }.tap do |combined_diff|
        diff_one.each do |change|
          combined_diff[change.old_position].first << change
        end

        diff_two.each do |change|
          combined_diff[change.old_position].last << change
        end
      end
    end

  end
end