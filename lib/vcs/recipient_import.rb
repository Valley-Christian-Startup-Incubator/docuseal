# frozen_string_literal: true

require 'csv'
require 'set'
require 'zip'
require 'nokogiri'

module Vcs
  # Reads data only: XLSX formulas, macros and external relationships are never evaluated.
  class RecipientImport
    Error = Class.new(StandardError)
    MAX_BYTES = 5 * 1024 * 1024
    MAX_EXPANDED_BYTES = 20 * 1024 * 1024
    MAX_ROWS = 1000
    attr_reader :rows, :headers

    def initialize(data, filename, template)
      raise Error, 'File exceeds 5 MB.' if data.bytesize > MAX_BYTES

      table = case File.extname(filename).downcase
              when '.csv' then CSV.parse(data.delete_prefix("\xEF\xBB\xBF"), field_size_limit: 20_000)
              when '.xlsx' then read_xlsx(data)
              else raise Error, 'Choose a CSV or XLSX file.'
              end
      @headers = Array(table.shift).map { |s| s.to_s.strip }
      raise Error, 'Column headings must be present and unique.' if headers.empty? || headers.any?(&:empty?) || headers.map(&:downcase).uniq.size != headers.size
      raise Error, 'Maximum 1,000 recipient rows per upload.' if table.size > MAX_ROWS

      roles = template.submitters.reject { |s| s['invite_by_uuid'].present? || s['optional_invite_by_uuid'].present? || s['invite_via_field_uuid'].present? }
      raise Error, 'Template has no recipient roles.' if roles.empty?

      @rows = table.each_with_index.filter_map do |cells, index|
        next if cells.all? { |c| c.to_s.strip.empty? }

        values = headers.zip(cells).to_h.transform_values { |v| v.to_s.strip }
        normalized = values.transform_keys(&:downcase)
        errors = []
        submitters = roles.map do |role|
          prefix = roles.size == 1 ? '' : "#{role['name'].downcase}."
          email = normalized["#{prefix}email"].to_s
          phone = normalized["#{prefix}phone"].to_s.gsub(/[\s-]/, '')
          if template.preferences['require_phone_2fa'] == true && !phone.match?(/\A\+[1-9]\d{7,14}\z/)
            errors << "#{prefix}phone must be an E.164 phone number"
          end
          errors << "#{prefix}email is missing or invalid" unless email.match?(User::FULL_EMAIL_REGEXP)
          field_values = template.fields.select { |f| f['submitter_uuid'] == role['uuid'] }.each_with_object({}) do |field, acc|
            key = "#{prefix}#{field['name']}".downcase
            acc[field['uuid']] = normalized[key] if normalized.key?(key)
          end
          { 'uuid' => role['uuid'], 'email' => email, 'phone' => phone.presence, 'name' => normalized["#{prefix}name"], 'values' => field_values }
        end
        { number: index + 2, submitters:, errors: }
      end
      raise Error, 'No recipients found.' if rows.empty?
      seen = Set.new
      rows.each do |row|
        identity = row[:submitters].map { |s| s['email'].downcase }
        row[:errors] << 'Duplicate recipient group in this file' unless seen.add?(identity)
      end
    rescue CSV::MalformedCSVError, EncodingError, Zip::Error, Nokogiri::XML::SyntaxError, ArgumentError, IndexError => e
      raise Error, "Unable to read spreadsheet: #{e.message.to_s.first(180)}"
    end

    def valid?
      rows.all? { |r| r[:errors].empty? }
    end

    private

    def xml(zip, name)
      entry = zip.find_entry(name)
      raise Error, "Missing XLSX part: #{name}" unless entry
      data = entry.get_input_stream.read(MAX_EXPANDED_BYTES + 1)
      raise Error, 'Expanded spreadsheet is too large.' if data.bytesize > MAX_EXPANDED_BYTES
      doc = Nokogiri::XML(data) { |config| config.strict.nonet }
      raise Error, 'XML document types are not supported.' if doc.internal_subset
      doc.remove_namespaces!
    end

    def read_xlsx(data)
      result = nil
      Zip::File.open_buffer(data) do |zip|
        raise Error, 'Expanded spreadsheet is too large.' if zip.entries.sum(&:size) > MAX_EXPANDED_BYTES
        strings = if zip.find_entry('xl/sharedStrings.xml')
                    xml(zip, 'xl/sharedStrings.xml').xpath('//si').map { |si| si.xpath('.//t').map(&:text).join }
                  else [] end
        sheet = xml(zip, 'xl/worksheets/sheet1.xml')
        result = sheet.xpath('//sheetData/row').map do |row|
          cells = []
          row.xpath('./c').each do |cell|
            ref = cell['r'].to_s[/\A[A-Z]+/]
            raise Error, 'Invalid cell reference.' unless ref
            index = ref.each_byte.reduce(0) { |n, b| n * 26 + b - 64 } - 1
            raise Error, 'Maximum 200 columns.' if index >= 200
            raise Error, 'Replace spreadsheet formulas with values before uploading.' if cell.at_xpath('./f')
            value = cell.at_xpath('./v')&.text
            cells[index] = case cell['t']
                           when 's' then strings.fetch(Integer(value))
                           when 'inlineStr' then cell.xpath('./is//t').map(&:text).join
                           else value end
          end
          cells
        end
      end
      result
    end
  end
end
