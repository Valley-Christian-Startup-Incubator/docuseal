# frozen_string_literal: true
require 'nokogiri'
require 'tmpdir'
require 'timeout'

module Vcs
  module HtmlPdf
    Error = Class.new(StandardError)
    module_function

    def call(html)
      raise Error, 'HTML exceeds 2 MB.' if html.bytesize > 2.megabytes
      doc = Nokogiri::HTML(html)
      doc.css('script, iframe, object, embed, link, base, meta, form, input, video, audio, source').remove
      doc.traverse do |node|
        next unless node.element?
        node.attribute_nodes.each do |attr|
          node.remove_attribute(attr.name) if attr.name.start_with?('on') || %w[href srcset action formaction].include?(attr.name)
        end
        node.remove_attribute('src') unless node['src'].to_s.match?(%r{\Adata:image/(png|jpeg|gif|webp);base64,}i)
      end
      head = doc.at_css('head') || doc.root.add_child('<head></head>').first
      head.prepend_child(%q(<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">))
      Dir.mktmpdir('vcs-html-') do |dir|
        input, output = File.join(dir, 'input.html'), File.join(dir, 'output.pdf')
        File.write(input, doc.to_html)
        pid = Process.spawn('/usr/bin/chromium-browser', '--headless', '--no-sandbox', '--disable-gpu',
          '--disable-dev-shm-usage', '--disable-background-networking', '--no-pdf-header-footer',
          '--host-resolver-rules=MAP * ~NOTFOUND', "--user-data-dir=#{dir}/profile", "--print-to-pdf=#{output}",
          "file://#{input}", out: File::NULL, err: File::NULL, pgroup: true)
        begin
          Timeout.timeout(25) { Process.wait(pid) }
          raise Error, 'HTML PDF generation failed.' unless File.exist?(output) && File.size(output).between?(1, 20.megabytes)
          File.binread(output)
        rescue Timeout::Error
          Process.kill('KILL', -pid) rescue nil
          Process.wait(pid) rescue nil
          raise Error, 'HTML PDF generation timed out.'
        end
      end
    end
  end
end
