# frozen_string_literal: true

module PuppetLanguageServer
  module Puppetfile
    module ValidationProvider
      def self.max_line_length
        # TODO: ... need to figure out the actual line length
        1000
      end

      def self.validate(content, _max_problems = 100)
        result = []
        # TODO: Need to implement max_problems
        _problems = 0

        # Attempt to parse the file
        puppetfile = nil
        begin
          puppetfile = PuppetLanguageServer::Puppetfile::R10K::Puppetfile.new
          puppetfile.load!(content)
        rescue StandardError, SyntaxError, LoadError => e
          # Find the originating error from within the puppetfile
          loc = e.backtrace_locations
                 .select { |item| item.absolute_path == PuppetLanguageServer::Puppetfile::R10K::PUPPETFILE_MONIKER }
                 .first
          start_line_number = loc.nil? ? 0 : loc.lineno - 1 # Line numbers from ruby are base 1
          end_line_number = loc.nil? ? content.lines.count - 1 : loc.lineno - 1 # Line numbers from ruby are base 1
          # Note - Ruby doesn't give a character position so just highlight the entire line
          result << LSP::Diagnostic.new('severity' => LSP::DiagnosticSeverity::ERROR,
                                        'range'    => LSP.create_range(start_line_number, 0, end_line_number, max_line_length),
                                        'source'   => 'Puppet',
                                        'message'  => e.to_s)

          puppetfile = nil
        end
        return result if puppetfile.nil?

        # Check for invalid module definitions
        puppetfile.modules.each do |mod|
          next unless mod.properties[:type] == :invalid
          # Note - Ruby doesn't give a character position so just highlight the entire line
          result << LSP::Diagnostic.new('severity' => LSP::DiagnosticSeverity::ERROR,
                                        'range'    => LSP.create_range(mod.puppetfile_line_number, 0, mod.puppetfile_line_number, max_line_length),
                                        'source'   => 'Puppet',
                                        'message'  => mod.properties[:error_message])
        end

        # Check for duplicate module definitions
        dupes = puppetfile.modules
                          .group_by { |mod| mod.name }
                          .select { |_, v| v.size > 1 }
                          .map(&:first)
        dupes.each do |dupe_module_name|
          puppetfile.modules.select { |mod| mod.name == dupe_module_name }.each do |puppet_module|
            # Note - Ruby doesn't give a character position so just highlight the entire line
            result << LSP::Diagnostic.new('severity' => LSP::DiagnosticSeverity::ERROR,
                                          'range'    => LSP.create_range(puppet_module.puppetfile_line_number, 0, puppet_module.puppetfile_line_number, max_line_length),
                                          'source'   => 'Puppet',
                                          'message'  => "Duplicate module definition for '#{puppet_module.name}'")
          end
        end

        result
      end
    end
  end
end
