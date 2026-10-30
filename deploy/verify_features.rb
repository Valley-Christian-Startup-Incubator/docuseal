# frozen_string_literal: true

raise 'Use an isolated database' unless ENV['VCS_ISOLATED_TEST'] == 'true'
require 'stringio'
require 'zip'
require 'nokogiri'
require 'sidekiq/testing'
Sidekiq::Testing.fake!
ActionController::Base.allow_forgery_protection = false

checks = 0
verify = lambda do |name, &block|
  raise "FAIL: #{name}" unless block.call
  checks += 1
  puts "PASS: #{name}"
end

account = Account.create!(name: 'VCS isolated test', locale: 'en', timezone: 'America/Los_Angeles')
password = 'SyntheticTest246!'
user = User.create!(account:, email: "vcs-test-#{SecureRandom.hex(4)}@example.invalid", password:, first_name: 'Test', last_name: 'Admin', confirmed_at: Time.current)
editor = User.create!(account:, email: "vcs-editor-#{SecureRandom.hex(4)}@example.invalid", password:, role: 'editor')
viewer = User.create!(account:, email: "vcs-viewer-#{SecureRandom.hex(4)}@example.invalid", password:, role: 'viewer')
other = Account.create!(name: 'Other test account', locale: 'en', timezone: 'America/Los_Angeles')
role = { 'uuid' => SecureRandom.uuid, 'name' => 'Signer' }
field = { 'uuid' => SecureRandom.uuid, 'submitter_uuid' => role['uuid'], 'type' => 'text', 'name' => 'Department', 'required' => false, 'areas' => [], 'preferences' => {} }
template = Template.create!(account:, author: user, name: 'Synthetic test', submitters: [role], fields: [field], schema: [])
verify.call('Editor can edit own account template') { Ability.new(editor).can?(:update, template) }
verify.call('Viewer cannot edit template or send submissions') { Ability.new(viewer).cannot?(:update, template) && Ability.new(viewer).cannot?(:create, Submission.new(account:)) }
verify.call('Editor cannot manage users or service settings') { Ability.new(editor).cannot?(:manage, user) && Ability.new(editor).cannot?(:update, EncryptedConfig.new(account:)) }
verify.call('Cross-account template is denied') { Ability.new(editor).cannot?(:read, Template.new(account: other)) }

csv = "email,name,Department\nsigner1@example.invalid,First,Science\nsigner2@example.invalid,Second,Arts\n"
parsed = Vcs::RecipientImport.new(csv, 'recipients.csv', template)
verify.call('CSV imports two rows with prefilled values') { parsed.valid? && parsed.rows.size == 2 && parsed.rows[0][:submitters][0]['values'][field['uuid']] == 'Science' }
invalid = Vcs::RecipientImport.new("email,name\nbad,Invalid\n", 'bad.csv', template)
verify.call('Invalid email requires correction') { !invalid.valid? }
duplicate = Vcs::RecipientImport.new("email\nsame@example.invalid\nSAME@example.invalid\n", 'duplicate.csv', template)
verify.call('Duplicate recipient groups require correction') { !duplicate.valid? }
bytes = Zip::OutputStream.write_buffer do |zip|
  zip.put_next_entry('xl/worksheets/sheet1.xml')
  zip.write('<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>email</t></is></c><c r="B1" t="inlineStr"><is><t>name</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>xlsx@example.invalid</t></is></c><c r="B2" t="inlineStr"><is><t>Spreadsheet Signer</t></is></c></row></sheetData></worksheet>')
end.string
verify.call('XLSX reads real zipped worksheet cells') { Vcs::RecipientImport.new(bytes, 'recipients.xlsx', template).rows[0][:submitters][0]['name'] == 'Spreadsheet Signer' }
template.preferences['require_phone_2fa'] = true
verify.call('Phone verification import requires an E.164 number') { !Vcs::RecipientImport.new(csv, 'recipients.csv', template).valid? }
template.preferences.delete('require_phone_2fa')

verify.call('Numeric formulas calculate precedence and rounding') { Vcs::Formula.new('round((2 + 3) * 4 / 3, 2)').call == 6.67 }
verify.call('Date formulas support calendar differences') { Vcs::Formula.new('datedif({{date}}, today(), "y")', values: { 'date' => '2000-11-01' }, fields: { 'date' => { 'type' => 'date' } }, today: Date.new(2026,10,30)).call == 25 }
%w[system("id") today()*2 abs(today())].each do |formula|
  raised = false
  begin
    Vcs::Formula.new(formula).call
  rescue Vcs::Formula::Error
    raised = true
  end
  verify.call("Unsafe or invalid formula rejected: #{formula}") { raised }
end

session = ActionDispatch::Integration::Session.new(Rails.application)
session.host! 'localhost'
session.post('/sign_in', params: { user: { email: user.email, password: } })
verify.call('Synthetic admin signs in') { session.response.redirect? }
session.get("/templates/#{template.id}/submissions/new")
verify.call('Recipient modal renders working upload controls') { session.response.status == 200 && session.response.body.include?('Review recipients') }
upload = Rack::Test::UploadedFile.new(StringIO.new(csv), 'text/csv', original_filename: 'recipients.csv')
session.post("/templates/#{template.id}/bulk_imports", params: { file: upload })
verify.call('Browser upload renders review with no submissions') { session.response.status == 200 && session.response.body.include?('Review recipients') && template.submissions.count.zero? }
doc = Nokogiri::HTML(session.response.body)
token = doc.at_css('input[name="token"]')&.[]('value')
action = doc.at_css('form[action*="bulk_imports/"]')&.[]('action')
raise 'Missing import confirmation form' unless token && action
session.patch(action, params: { token:, send_email: '0' })
verify.call('Confirmed import persists two complete recipient groups') { session.response.redirect? && template.submissions.count == 2 && template.submissions.sum { |s| s.submitters.size } == 2 }
session.patch(action, params: { token:, send_email: '0' })
verify.call('Confirmation replay creates no duplicate submissions') { template.submissions.count == 2 }

config = AccountConfig.create!(account:, key: AccountConfig::SUBMITTER_REMINDERS, value: { 'first_duration' => 'one_hour' })
recipient = template.submissions.first.submitters.first
recipient.update!(sent_at: 2.hours.ago, preferences: { 'send_email' => true })
EncryptedConfig.create!(account:, key: EncryptedConfig::EMAIL_SMTP_KEY, value: { 'from_email' => 'test@example.invalid' })
unsent = template.submissions.last.submitters.first
unsent.update!(sent_at: nil, preferences: { 'send_email' => true })
SendSubmitterInvitationEmailJob.clear
SendSubmitterRemindersJob.new.perform
recipient_jobs = -> { SendSubmitterInvitationEmailJob.jobs.select { |job| job['args'][0]['submitter_id'] == recipient.id } }
count = recipient_jobs.call.size
SendSubmitterRemindersJob.new.perform
verify.call('Reminder scan queues once across repeated runs') { count == 1 && recipient_jobs.call.size == 1 }
verify.call('Unsent recipients stay unsent and do not receive reminders') { unsent.reload.sent_at.nil? && SendSubmitterInvitationEmailJob.jobs.none? { |job| job['args'][0]['submitter_id'] == unsent.id } }
recipient.update!(completed_at: Time.current)
SendSubmitterRemindersJob.new.perform
verify.call('Completed recipient receives no new reminders') { recipient_jobs.call.size == 1 }

pdf = Vcs::HtmlPdf.call('<h1>VCS HTML API verification</h1><p>{{Signature;type=signature;role=Signer}}</p>')
verify.call('HTML renderer generates a PDF') { pdf.start_with?('%PDF') }
blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(pdf), filename: 'synthetic.pdf', content_type: 'application/pdf')
attachment = template.documents.create!(blob:)
tags = Vcs::FieldTags.extract(template, attachment)
verify.call('PDF tag becomes a positioned signature field') { tags.size == 1 && tags[0]['type'] == 'signature' && tags[0]['areas'][0]['w'] > 0 }

headers = { 'X-Auth-Token' => user.access_token.token }
session.post('/api/templates/pdf', params: { name: 'PDF API test', documents: [{ name: 'test.pdf', file: Base64.strict_encode64(pdf) }] }, headers:, as: :json)
verify.call('Authenticated PDF template API creates fields from tags') { session.response.status == 201 && JSON.parse(session.response.body)['fields'].size == 1 }
session.post('/api/templates/html', params: { name: 'HTML API test', documents: [{ name: 'test', html: '<h1>HTML template</h1><p>{{Name;type=text;role=Signer}}</p>' }] }, headers:, as: :json)
verify.call('Authenticated HTML template API creates a template') { session.response.status == 201 }


verify.call('Redacted document hash matches stored PDF bytes') { attachment.metadata['sha256'] == Base64.urlsafe_encode64(Digest::SHA256.digest(attachment.download)) }
verify.call('Field tags are removed from the original PDF') { Pdfium::Document.open_bytes(attachment.download) { |doc| !doc.get_page(0).text.include?('{{Signature') } }
acro = HexaPDF::Document.new
page = acro.pages.add
acro.acro_form(create: true).create_text_field('Legal name').create_widget(page, Rect: [50, 600, 250, 630])
io = StringIO.new
acro.write(io)
session.post('/api/templates/pdf', params: { name: 'AcroForm API test', documents: [{ name: 'acro.pdf', file: Base64.strict_encode64(io.string) }] }, headers:, as: :json)
verify.call('AcroForm PDF without tags preserves existing field') { session.response.status == 201 && JSON.parse(session.response.body)['fields'].size == 1 }

docx = Zip::OutputStream.write_buffer do |zip|
  zip.put_next_entry('[Content_Types].xml')
  zip.write('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
  zip.put_next_entry('_rels/.rels')
  zip.write('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
  zip.put_next_entry('word/document.xml')
  zip.write('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>VCS Word form {{Signature;type=signature;role=Signer}}</w:t></w:r></w:p></w:body></w:document>')
end.string
session.post('/api/templates/docx', params: { name: 'DOCX API test', documents: [{ name: 'word.docx', file: Base64.strict_encode64(docx) }] }, headers:, as: :json)
verify.call('DOCX API converts a real Word document and extracts its field') { session.response.status == 201 && JSON.parse(session.response.body)['fields'].size == 1 }
session.post('/api/templates/pdf', params: { documents: ['bad'] }, headers:, as: :json)
verify.call('Malformed template API request returns validation error') { session.response.status == 422 }
[{documents:[nil]}, {documents:[{file:nil}]}, {documents:[{file:'AA==',name:123}]}].each do |bad|
  session.post('/api/templates/pdf', params: bad, headers:, as: :json)
  verify.call('Malformed document fields are rejected before processing') { session.response.status == 422 }
end

anonymous = ActionDispatch::Integration::Session.new(Rails.application)
anonymous.host! 'localhost'
phone_recipient = template.submissions.last.submitters.first
phone_recipient.update!(phone: '+14085550123', preferences: { 'require_phone_2fa' => true })
anonymous.get("/s/#{phone_recipient.slug}")
verify.call('Unverified phone recipient sees verification screen') { anonymous.response.status == 200 && anonymous.response.body.include?('one_time_code') && !anonymous.response.body.include?('<submission-form') }
anonymous.put("/s/#{phone_recipient.slug}", params: { completed: true })
verify.call('Phone verification cannot be bypassed by posting form values') { anonymous.response.status == 422 && !phone_recipient.reload.completed_at? }
value = "#{phone_recipient.phone}:#{phone_recipient.slug}"
code = OtpChallenges.generate(value, purpose: 'form_phone_2fa')
anonymous.post("/s/#{phone_recipient.slug}/phone_verification", params: { one_time_code: code })
anonymous.get("/s/#{phone_recipient.slug}")
verify.call('Valid phone OTP permits the signing form') { anonymous.response.status == 200 && anonymous.response.body.include?('<submission-form') }
verify.call('Phone OTP cannot be reused') { !OtpChallenges.verify(code, value, purpose: 'form_phone_2fa') }
phone_recipient.update!(completed_at: Time.current)
anonymous.patch("/s/#{phone_recipient.slug}/phone_verification")
verify.call('Completed documents cannot trigger verification SMS') { anonymous.response.status == 404 }

viewer_session = ActionDispatch::Integration::Session.new(Rails.application)
viewer_session.host! 'localhost'
viewer_session.post('/sign_in', params: { user: { email: viewer.email, password: } })
viewer_session.patch("/templates/#{template.id}", params: { template: { name: 'Unauthorized mutation' } })
verify.call('Viewer HTTP template mutation is denied') { template.reload.name != 'Unauthorized mutation' && viewer_session.response.redirect? }

puts "#{checks} isolated feature checks passed."
