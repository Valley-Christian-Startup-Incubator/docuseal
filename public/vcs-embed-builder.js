(() => {
  if (!document.querySelector('meta[name="vcs-embed-token"]')) return

  const url = new URL(window.location.href)
  url.searchParams.delete('token')
  window.history.replaceState(null, '', url)
})()
