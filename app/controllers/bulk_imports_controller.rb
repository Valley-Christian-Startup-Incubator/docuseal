# frozen_string_literal: true

class BulkImportsController < ApplicationController
  load_and_authorize_resource :template
  before_action { authorize!(:create, Submission.new(account: current_account)) }

  def create
    file = params.require(:file)
    data = file.read(Vcs::RecipientImport::MAX_BYTES + 1)
    @import = Vcs::RecipientImport.new(data, file.original_filename, @template)
    @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(data), filename: file.original_filename,
      content_type: 'application/octet-stream', metadata: { vcs_import_user: current_user.id, vcs_import_template: @template.id })
    @token = @blob.signed_id(purpose: :vcs_import, expires_in: 1.hour)
    render :review
  rescue Vcs::RecipientImport::Error, ActionController::ParameterMissing => e
    redirect_to template_path(@template), alert: e.message
  end

  def update
    blob = ActiveStorage::Blob.find_signed!(params.require(:token), purpose: :vcs_import)
    raise CanCan::AccessDenied unless blob.metadata['vcs_import_user'] == current_user.id && blob.metadata['vcs_import_template'] == @template.id

    submissions = blob.with_lock do
      next Submission.where(id: blob.metadata['vcs_import_submission_ids']).to_a if blob.metadata['vcs_import_consumed']
      raise Vcs::RecipientImport::Error, 'Template is archived.' if @template.archived_at?
      import = Vcs::RecipientImport.new(blob.download, blob.filename.to_s, @template)
      raise Vcs::RecipientImport::Error, 'Correct the invalid rows and upload again.' unless import.valid?
      attrs = import.rows.map { |r| { 'submitters' => r[:submitters] }.with_indifferent_access }
      attrs, _, new_fields = Submissions::NormalizeParamUtils.normalize_submissions_params!(attrs, @template, add_fields: false)
      result = Submissions.create_from_submitters(template: @template, user: current_user, source: :invite,
        submissions_attrs: attrs, new_fields:, params: { 'send_email' => params[:send_email] == '1', 'send_completed_email' => true })
      blob.update!(metadata: blob.metadata.merge('vcs_import_consumed' => true, 'vcs_import_submission_ids' => result.map(&:id)))
      result
    end
    Vcs::ImportDelivery.dispatch(blob)
    redirect_to template_path(@template), notice: "Imported #{submissions.size} recipient groups."
  rescue Vcs::RecipientImport::Error, Submissions::CreateFromSubmitters::BaseError => e
    redirect_to template_path(@template), alert: e.message
  end
end
