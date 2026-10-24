#!/bin/bash
# Starts the paper report app, the web interface and nginx, which serves the
# website and passes /metacheck/ and /api/ on. When any of them stops, this
# script stops, and so does the container, so that Docker never keeps a
# half-working website running. GROBID is not started here: it is TU/e's
# server, or the GROBID container next to this one (compose.yaml).
set -u

(cd /srv/metacheck-app && exec R --no-save --quiet -e \
  "shiny::runApp('.', host = '127.0.0.1', port = 3839, launch.browser = FALSE)") &
app_pid=$!

(cd /srv/metacheck-api && exec Rscript -e \
  "plumber::pr_run(plumber::plumb('api.R'), host = '127.0.0.1', port = 2005, docs = TRUE)") &
api_pid=$!

nginx -g "daemon off;" &
nginx_pid=$!

# Say so once the web interface answers, and the GROBID container when there
# is one (it takes longer to start). Where PDFs go, and which language model
# the power check uses, so the person starting it sees what leaves the computer.
(
  for _ in $(seq 1 120); do
    if curl -sf http://localhost:3838/api/health > /dev/null &&
       { [ -z "${GROBID_LOCAL_URL:-}" ] || curl -sf "$GROBID_LOCAL_URL/api/isalive" > /dev/null; }; then
      if [ -n "${GROBID_LOCAL_URL:-}" ]; then
        echo "PDFs: converted by the GROBID container on this computer"
      else
        echo "PDFs: sent to the GROBID server at ${METACHECK_GROBID_URL} for conversion"
        surf="${SURF_API_URL:-https://metacheckserve.metacheck.src.surf-hosted.nl/api}"
        if [ "${METACHECK_CONVERT_BACKUP:-}" = "surf" ]; then
          echo "      (when it does not answer: metacheck's server on SURF Research Cloud)"
        fi
        if ! curl -sf -m 20 "${METACHECK_GROBID_URL}/api/isalive" > /dev/null; then
          if [ "${METACHECK_CONVERT_BACKUP:-}" = "surf" ] && curl -sf -m 20 "$surf/health" > /dev/null; then
            echo "NOTE: that GROBID server does not answer now; PDFs go to metacheck's server on"
            echo "      SURF Research Cloud instead"
          else
            echo "WARNING: that GROBID server does not answer now, so PDFs cannot be converted;"
            echo "         try again later, or switch on GROBID on this computer (see the README)"
          fi
        fi
      fi
      if [ -n "${OLLAMA_BASE_URL:-}" ]; then
        echo "Language model: Ollama on this computer (${METACHECK_LLM_MODEL})"
      elif [ -n "${MISTRAL_API_KEY:-}" ]; then
        echo "Language model: Mistral (EU), with your own API key"
      else
        echo "Language model: none (see the README to add one)"
      fi
      echo "metacheck is ready: open http://localhost:3838 in your browser"
      exit 0
    fi
    sleep 2
  done
  echo "metacheck did not start within 4 minutes"
) &

wait -n "$app_pid" "$api_pid" "$nginx_pid"
exit $?
