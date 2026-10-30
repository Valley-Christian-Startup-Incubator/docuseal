# frozen_string_literal: true
module Vcs
  module FieldTags
    TYPES = %w[text signature initials date number checkbox].freeze
    module_function
    def extract(template, attachment)
      fields = []
      redacted = false
      Pdfium::Document.open_bytes(attachment.download) do |pdf|
        pdf.page_count.times do |index|
          nodes = pdf.get_page(index).text_nodes
          text = nodes.map(&:content).join
          redactions = []
          text.to_enum(:scan, /\{\{([^{}]+)\}\}/).each do
            match = Regexp.last_match
            parts = match[1].split(';').map(&:strip)
            name = parts.shift
            options = parts.filter_map { |p| p.split('=', 2) if p.include?('=') }.to_h
            next unless options['type']
            type = options['type']
            raise ArgumentError, "Unsupported field tag type: #{type}" unless TYPES.include?(type)
            role_name = options['role'].presence || 'Signer'
            role = template.submitters.find { |s| s['name'] == role_name }
            unless role
              role = { 'name' => role_name, 'uuid' => SecureRandom.uuid }
              template.submitters << role
            end
            chars = nodes[match.begin(0)...match.end(0)]
            x, y = chars.map(&:x).min, chars.map(&:y).min
            right = chars.map { |n| n.x + n.w }.max
            bottom = chars.map { |n| n.y + n.h }.max
            redactions << { 'x' => x, 'y' => y, 'w' => right - x, 'h' => bottom - y, 'color' => '#FFFFFF' }
            fields << { 'uuid' => SecureRandom.uuid, 'name' => name, 'type' => type,
              'submitter_uuid' => role['uuid'], 'required' => options.fetch('required', 'true') != 'false',
              'preferences' => {}, 'areas' => [{ 'attachment_uuid' => attachment.uuid, 'page' => index,
                'x' => x, 'y' => y, 'w' => [right - x, 0.2, 1 - x].sort[1].clamp(0.01, 1 - x),
                'h' => [bottom - y, 0.035].max.clamp(0.01, 1 - y) }] }
          end
          unless redactions.empty?
            pdf.get_page(index).redact(redactions)
            redacted = true
          end
        end
        if redacted
          io = StringIO.new
          pdf.save(io)
          original = attachment.blob
          metadata = original.metadata.merge('sha256' => Base64.urlsafe_encode64(Digest::SHA256.digest(io.string)))
          replacement = ActiveStorage::Blob.create_and_upload!(io: io.tap(&:rewind), filename: original.filename, content_type: 'application/pdf', metadata:)
          attachment.update!(blob: replacement)
          original.purge_later
        end
      end
      if redacted
        Pdfium::Document.open_bytes(attachment.download) do |pdf|
          Templates::ProcessDocument.call(attachment, attachment.download, doc: pdf)
        end
      end
      fields
    end
  end
end
