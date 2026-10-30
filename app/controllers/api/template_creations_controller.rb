# frozen_string_literal: true
module Api
  class TemplateCreationsController < ApiBaseController
    def create
      template = current_account.templates.new(author: current_user, name: params[:name].presence || 'Untitled document', source: :api)
      authorize!(:create, template)
      raise ArgumentError, 'Provide 1–10 documents.' unless params[:documents].is_a?(Array) && params[:documents].size.between?(1, 10)
      files = params[:documents].map do |document|
        document = document.to_unsafe_h if document.respond_to?(:to_unsafe_h)
        raise ArgumentError, 'Each document must be an object.' unless document.is_a?(Hash)
        raise ArgumentError, 'Document name must be a string.' unless document['name'].nil? || document['name'].is_a?(String)
        filename = document['name'].presence || 'document'
        filename = "#{File.basename(filename, '.*')}.#{params[:format_type] == 'docx' ? 'docx' : 'pdf'}"
        if params[:format_type] == 'html'
          html = document.fetch('html')
          raise ArgumentError, 'html must be a string.' unless html.is_a?(String)
          data = Vcs::HtmlPdf.call(html)
          filename = "#{File.basename(filename, '.*')}.pdf"
          type = 'application/pdf'
        else
          encoded = document.fetch('file')
          raise ArgumentError, 'file must be base64 content up to 28 MB.' unless encoded.is_a?(String) && encoded.bytesize <= 28.megabytes
          data = Base64.strict_decode64(encoded.sub(/\Adata:[^,]*,/, ''))
          type = params[:format_type] == 'docx' ? Templates::CreateAttachments::DOCUMENT_CONTENT_TYPES.first : 'application/pdf'
        end
        raise ArgumentError, 'Document exceeds 20 MB.' if data.bytesize > 20.megabytes
        ActionDispatch::Http::UploadedFile.new(tempfile: StringIO.new(data), filename:, type:)
      end
      raise ArgumentError, 'Provide 1–10 documents.' unless files.size.between?(1, 10)
      template.transaction do
        template.save!
        documents, = Templates::CreateAttachments.call(template, { files: }, extract_fields: true)
        template.schema = documents.map { |d| { 'attachment_uuid' => d.uuid, 'name' => d.filename.base } }
        template.submitters = []
        template.fields = documents.flat_map { |d| Vcs::FieldTags.extract(template, d) }
        if template.fields.empty?
          template.submitters = [{ 'name' => 'Signer', 'uuid' => SecureRandom.uuid }] if template.submitters.empty?
          template.fields = Templates::ProcessDocument.normalize_attachment_fields(template, documents)
        end
        template.submitters = [{ 'name' => 'Signer', 'uuid' => SecureRandom.uuid }] if template.submitters.empty?
        template.save!
      end
      SearchEntries.enqueue_reindex(template)
      WebhookUrls.enqueue_events([template], 'template.created')
      render json: Templates::SerializeForApi.call(template), status: :created
    rescue ArgumentError, KeyError, Vcs::HtmlPdf::Error, Templates::CreateAttachments::InvalidFileType, Pdfium::PdfiumError => e
      render json: { error: e.message }, status: :unprocessable_content
    end
  end
end
