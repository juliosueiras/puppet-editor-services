# frozen_string_literal: true

module PuppetLanguageServer
  module PuppetHelper
    class Cache
      SECTIONS = %i[class type function datatype].freeze
      ORIGINS = %i[default workspace].freeze

      def initialize(_options = {})
        @cache_lock = Mutex.new
        @inmemory_cache = {}
        # The cache consists of hash of hashes
        # @inmemory_cache[<origin>][<section>] = [ Array of SidecarProtocol Objects ]
      end

      def import_sidecar_list!(list, section, origin)
        return if origin.nil?
        return if section.nil?
        list = [] if list.nil?

        @cache_lock.synchronize do
          # Remove the existing items
          remove_section_impl(section, origin)
          # Set the list
          @inmemory_cache[origin] = {} if @inmemory_cache[origin].nil?
          @inmemory_cache[origin][section] = list
        end
        nil
      end

      def remove_section!(section, origin = nil)
        @cache_lock.synchronize do
          remove_section_impl(section, origin)
        end
        nil
      end

      # section => <Type of object in the file :function, :type, :class, :datatype>
      def object_by_name(section, name)
        name = name.intern if name.is_a?(String)
        return nil if section.nil?
        @cache_lock.synchronize do
          @inmemory_cache.each do |_, sections|
            next if sections[section].nil? || sections[section].empty?
            sections[section].each do |item|
              return item if item.key == name
            end
          end
        end
        nil
      end

      # section => <Type of object in the file :function, :type, :class, :datatype>
      def object_names_by_section(section)
        result = []
        return result if section.nil?
        @cache_lock.synchronize do
          @inmemory_cache.each do |_, sections|
            next if sections[section].nil? || sections[section].empty?
            result.concat(sections[section].map { |i| i.key })
          end
        end
        result.uniq!
        result.compact
      end

      # section => <Type of object in the file :function, :type, :class, :datatype>
      def objects_by_section(section, &_block)
        return if section.nil?
        @cache_lock.synchronize do
          @inmemory_cache.each do |_, sections|
            next if sections[section].nil? || sections[section].empty?
            sections[section].each { |i| yield i.key, i }
          end
        end
      end

      def all_objects(&_block)
        @cache_lock.synchronize do
          @inmemory_cache.each do |_origin, sections|
            sections.each do |_section_name, list|
              list.each { |i| yield i.key, i }
            end
          end
        end
      end

      private

      def remove_section_impl(section, origin = nil)
        @inmemory_cache.each do |list_origin, sections|
          next unless origin.nil? || list_origin == origin
          sections[section].clear unless sections[section].nil?
        end
      end
    end
  end
end
