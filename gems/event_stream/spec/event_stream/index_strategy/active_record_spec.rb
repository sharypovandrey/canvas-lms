#
# Copyright (C) 2020 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require 'spec_helper'

describe EventStream::IndexStrategy::ActiveRecord do
  before :each do
    @fake_record_type = Class.new do
      def created_at
        @_created_val ||= Time.zone.now
      end

      def self.paginate(options={})
        self
      end

      def self.to_ary
        [self.new]
      end

      def self.next_page
        self
      end
    end
  end

  describe "#for_ar_scope" do

    it "loads records from DB" do
      query_options = {}
      stream = double('stream',
                     :record_type => EventStream::Record,
                     :active_record_type => @fake_record_type)
      base_index = EventStream::Index.new(stream) do
        self.table "table"
        self.entry_proc lambda{|a1, a2| nil}
        self.ar_conditions_proc lambda {|a1, a2| { one: a1.id, two: a2.id}}
      end
      index = base_index.strategy_for(:active_record)
      arg1 = double('arg1', :id => "abc")
      arg2 = double('arg2', :id => "def")
      expect(@fake_record_type).to receive(:where).with({ one: 'abc', two: 'def'}).and_return(@fake_record_type)
      expect(@fake_record_type).to receive(:order).with("created_at DESC").and_return(@fake_record_type)
      outcome = index.for_ar_scope([arg1, arg2], {})
      outcome.paginate(per_page: 10)
    end
  end


  describe "internal Bookmarker" do
    it "just uses the created_at field for bookmarking" do
      bookmarker = EventStream::IndexStrategy::ActiveRecord::Bookmarker.new(@fake_record_type)
      model = @fake_record_type.new
      bookmark_value = bookmarker.bookmark_for(model)
      expect(bookmark_value).to eq(model.created_at)
      expect(bookmarker.validate(bookmark_value)).to eq(true)
    end
  end
end