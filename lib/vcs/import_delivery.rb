# frozen_string_literal: true
module Vcs
  module ImportDelivery
    module_function
    def dispatch(blob)
      blob.with_lock do
        return if blob.metadata['vcs_import_dispatched']
        submissions = Submission.where(id: blob.metadata.fetch('vcs_import_submission_ids')).to_a
        WebhookUrls.enqueue_events(submissions, 'submission.created')
        Submissions.send_signature_requests(submissions, delivery_key: "import:#{blob.id}")
        SearchEntries.enqueue_reindex(submissions)
        blob.update!(metadata: blob.metadata.merge('vcs_import_dispatched' => true))
      end
    end
  end
end
