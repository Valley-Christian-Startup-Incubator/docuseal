# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'

source = Pathname.new(ENV.fetch('VCS_INTERNSHIP_DIR'))
blueprint = JSON.parse(source.join('blueprint.json').read)
fingerprint = Digest::SHA256.hexdigest(source.join('blueprint.json').read)
user = User.active.admins.order(:id).first!
account = user.account
config = account.account_configs.find_or_initialize_by(key: 'vcs_internship')
config.value ||= {}
config.save! if config.new_record?

config.with_lock do
  school_email = ENV['VCS_INTERNSHIP_SCHOOL_EMAIL'].presence || config.value['school_email']
  issuer_email = ENV['VCS_INTERNSHIP_ISSUER_EMAIL'].presence || config.value['issuer_email']
  issuer_is_separate = issuer_email.present? && issuer_email.downcase != school_email.to_s.downcase
  template = account.templates.find_by(external_id: 'vcs-internship-2027-v1')
  if template
    raise 'Existing packet blueprint differs. Create a reviewed new template version.' if template.preferences['vcs_blueprint_sha256'] != fingerprint
    if template.submitters.any? { |role| role['vcs_role'] == 'issuer' } != issuer_is_separate
      raise 'Existing packet has a different work permit signer. Create a reviewed new template version.'
    end
  else
    roles = %w[student parent host school]
    roles << 'issuer' if issuer_is_separate
    labels = { 'student' => 'Student', 'parent' => 'Parent or guardian', 'host' => 'Host employer',
               'school' => 'School representative', 'issuer' => 'Work permit issuer' }
    role_index = roles.index_with { |role| { 'uuid' => SecureRandom.uuid, 'name' => labels.fetch(role), 'vcs_role' => role, 'order' => role == 'student' ? 0 : %w[parent host].include?(role) ? 1 : 2 } }
    role_index['issuer'] = role_index.fetch('school') unless issuer_is_separate
    template = account.templates.create!(author: user, name: 'Summer 2027 internship packet',
      external_id: 'vcs-internship-2027-v1', shared_link: false, submitters: roles.map { |role| role_index.fetch(role) },
      preferences: { 'vcs_internship' => true, 'vcs_blueprint_sha256' => fingerprint,
                     'submitters_order' => 'preserved', 'require_all_submitters' => true,
                     'require_email_2fa' => true, 'shared_link_2fa' => false,
                     'documents_copy_email_enabled' => false, 'completed_notification_email_enabled' => true,
                     'completed_notification_email_attach_documents' => false,
                     'completed_notification_email_attach_audit' => false,
                     'request_email_subject' => 'Summer 2027 internship packet - your signature is requested' })
    attachments = {}
    blueprint.fetch('documents').each do |document|
      filename = document.fetch('filename')
      raise 'Invalid input filename' if File.basename(filename) != filename
      data = source.join(filename).binread
      raise "Input checksum mismatch for #{filename}" unless Digest::SHA256.hexdigest(data) == document.fetch('sha256')
      file = ActionDispatch::Http::UploadedFile.new(tempfile: StringIO.new(data), filename:, type: 'application/pdf')
      attachment = Templates::CreateAttachments.handle_pdf_or_image(template, file, data)
      attachments[document.fetch('slot')] = attachment
    end
    template.schema = blueprint.fetch('documents').map do |document|
      { 'attachment_uuid' => attachments.fetch(document.fetch('slot')).uuid, 'name' => document.fetch('name') }
    end
    template.fields = blueprint.fetch('fields').map do |item|
      attrs = item.slice('name', 'type', 'required', 'readonly', 'default_value', 'description', 'preferences')
      attrs.merge('uuid' => SecureRandom.uuid, 'submitter_uuid' => role_index.fetch(item.fetch('role')).fetch('uuid'),
        'areas' => item.fetch('areas').map do |area|
          area.except('document').merge('attachment_uuid' => attachments.fetch(area.fetch('document')).uuid)
        end)
    end
    template.save!
  end
  values = config.value.merge('template_id' => template.id)
  { 'school_email' => ENV['VCS_INTERNSHIP_SCHOOL_EMAIL'], 'issuer_email' => ENV['VCS_INTERNSHIP_ISSUER_EMAIL'],
    'school_name' => ENV['VCS_INTERNSHIP_SCHOOL_NAME'], 'issuer_name' => ENV['VCS_INTERNSHIP_ISSUER_NAME'] }.each do |key, value|
    values[key] = value.strip if value.present?
  end
  values['enabled'] = ENV['VCS_INTERNSHIP_ENABLE'] == 'true'
  if values['enabled']
    raise 'School signer email required' unless values['school_email'].to_s.match?(User::FULL_EMAIL_REGEXP)
    if template.submitters.any? { |role| role['vcs_role'] == 'issuer' }
      raise 'Work permit issuer email required' unless values['issuer_email'].to_s.match?(User::FULL_EMAIL_REGEXP)
    end
  end
  config.update!(value: values)
  puts JSON.generate(template_id: template.id, documents: template.schema.size, fields: template.fields.size,
    signers: template.submitters.size, enabled: values['enabled'])
end
