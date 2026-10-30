# frozen_string_literal: true

class EmbedScriptsController < ActionController::Metal
  EMBED_SCRIPT = <<~JAVASCRIPT.freeze
    (() => {
      const script = document.currentScript;
      if (!script) return;
      const host = new URL(script.src).origin;

      function register(name, builder) {
        if (window.customElements.get(name)) return;
        window.customElements.define(name, class extends HTMLElement {
          static get observedAttributes() { return ['src']; }
          connectedCallback() { this.renderFrame(); }
          attributeChangedCallback() { if (this.isConnected) this.renderFrame(); }
          renderFrame() {
            let url;
            try { url = new URL(this.getAttribute('src'), host); } catch (_) { return; }
            const path = builder ? /^\\/embed\\/builders\\/\\d+$/ : /^\\/[sd]\\/[^/]+$/;
            if (!['https:', 'http:'].includes(url.protocol) || url.origin !== host || !path.test(url.pathname)) {
              this.replaceChildren(document.createTextNode('Invalid document embed URL.'));
              return;
            }
            if (!builder) url.searchParams.set('embed', '1');
            const frame = document.createElement('iframe');
            frame.src = url.href;
            frame.title = this.getAttribute('title') || (builder ? 'Document template editor' : 'Sign document');
            frame.referrerPolicy = 'no-referrer';
            frame.allow = 'camera';
            frame.style.cssText = 'display:block;width:100%;min-height:700px;height:100%;border:0';
            this.style.display = 'block';
            this.replaceChildren(frame);
          }
        });
      }
      register('docuseal-form', false);
      register('docuseal-builder', true);
    })();
  JAVASCRIPT

  def show
    headers['Content-Type'] = 'application/javascript'
    headers['X-Content-Type-Options'] = 'nosniff'
    headers['Cache-Control'] = 'public, max-age=300'
    self.response_body = EMBED_SCRIPT
    self.status = 200
  end
end
