#!/bin/sh
set -eu
export PATH=/opt/homebrew/bin:/usr/bin:/bin
export DOCKER_CONTEXT=colima
vcs_container=$(python3 -c 'import json,pathlib; print(json.loads((pathlib.Path.home()/".local/share/docuseal/deploy/state.json").read_text())["active"]["container"])')
docker exec -w /app "$vcs_container" bundle exec rails runner 'SendSubmitterRemindersJob.perform_async'
