# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# metacheck on your own computer: the website, web interface and paper report
# app of the SURF Research Cloud server, in one image.
#
# Ubuntu 24.04 with R, Quarto, metacheck, nginx and the website (site/), web
# interface (api/) and paper report app (app/) of
# scienceverse/surf-research-cloud. The R packages come from r2u, as on the
# SURF server. Runs on Intel/AMD and ARM (Apple Silicon) processors. PDFs are
# converted by TU/e's GROBID server, or by the GROBID container that
# compose.yaml adds (profile "grobid"); the language model is Ollama on the
# user's computer or Mistral with the user's own key (see README).
# ---------------------------------------------------------------------------

# The website, web interface and app. To build with a local copy instead:
#   docker build --build-context surf=../surf-research-cloud .
ARG SURF_REPO=https://github.com/scienceverse/surf-research-cloud.git#main
ARG METACHECK_REF=dev

FROM scratch AS surf
ARG SURF_REPO
ADD ${SURF_REPO} /

# metacheck as a git checkout of METACHECK_REF: Docker takes it again when the
# branch has a new commit (without GitHub's API, which limits the requests
# of shared build machines). The package and the API helper code below come
# from this one commit.
FROM scratch AS metacheck-src
ARG METACHECK_REF
ADD https://github.com/scienceverse/metacheck.git#${METACHECK_REF} /

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive TZ=UTC LANG=C.UTF-8

# apt tries a download again when a server does not answer (on GitHub's build
# machines, r2u's server once timed out), and every apt-get update below stops
# the build when a package list cannot be downloaded, instead of failing later
# with "Unable to locate package". tini starts the programs and passes a stop
# signal on to them.
RUN printf 'Acquire::Retries "5";\nAcquire::http::Timeout "60";\nAcquire::https::Timeout "60";\nAPT::Update::Error-Mode "any";\n' \
      > /etc/apt/apt.conf.d/80-metacheck && \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl tini && \
    rm -rf /var/lib/apt/lists/*

# R from CRAN's Ubuntu repository, CRAN packages as Ubuntu binaries from r2u.
RUN curl -fsSL https://eddelbuettel.github.io/r2u/assets/dirk_eddelbuettel_key.asc \
      -o /etc/apt/trusted.gpg.d/cranapt_key.asc && \
    curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
      -o /etc/apt/trusted.gpg.d/cran_ubuntu_key.asc && \
    echo "deb https://r2u.stat.illinois.edu/ubuntu noble main" \
      > /etc/apt/sources.list.d/cranapt.list && \
    echo "deb https://cloud.r-project.org/bin/linux/ubuntu noble-cran40/" \
      > /etc/apt/sources.list.d/cran_r.list && \
    printf 'Package: *\nPin: release o=CRAN-Apt Project\nPin: release l=CRAN-Apt Packages\nPin-Priority: 700\n' \
      > /etc/apt/preferences.d/99cranapt && \
    apt-get update && \
    apt-get install -y --no-install-recommends r-base-core && \
    rm -rf /var/lib/apt/lists/*

# The R packages of the SURF server's metacheck component (metacheck.yml,
# r_packages), plus what the web interface's helper code uses; nginx serves
# the website; Python runs the Python code of the reproducibility check.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      r-cran-remotes r-cran-shiny r-cran-shinydashboard r-cran-shinyjs \
      r-cran-dt r-cran-dplyr r-cran-tidyr r-cran-readr r-cran-knitr \
      r-cran-rmarkdown r-cran-quarto r-cran-bibtex r-cran-ellmer \
      r-cran-jsonlite r-cran-xml2 r-cran-curl r-cran-httr2 r-cran-rvest \
      r-cran-rappdirs r-cran-tidytext r-cran-statcheck r-cran-base64enc \
      r-cran-gitcreds r-cran-roxygen2 r-cran-jpeg r-cran-progress \
      r-cran-ggplot2 r-cran-callr r-cran-processx \
      r-cran-careless r-cran-readods r-cran-openxlsx r-cran-haven \
      r-cran-readxl r-cran-data.table r-cran-officer r-cran-pdftools \
      r-cran-snowballc r-cran-yaml r-cran-dbi r-cran-rsqlite r-cran-zip \
      r-cran-digest \
      r-cran-plumber r-cran-logger r-cran-promises r-cran-later \
      r-cran-uuid r-cran-webutils r-cran-mime \
      nginx python3 python3-pip && \
    rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/default

ARG QUARTO_VERSION=1.10.19
RUN arch="$(dpkg --print-architecture)" && \
    curl -fsSL -o /tmp/quarto.deb \
      "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-${arch}.deb" && \
    apt-get update && apt-get install -y --no-install-recommends /tmp/quarto.deb && \
    rm -rf /tmp/quarto.deb /var/lib/apt/lists/*

# Packages that the code of a checked repository needs and the image lacks
# are installed by the reproducibility check while it runs, into a throwaway
# library: ready-made Linux packages from Posit's package manager, so no
# compiler is needed (see Rprofile.packagemanager).
COPY Rprofile.packagemanager /tmp/Rprofile.packagemanager
RUN cat /tmp/Rprofile.packagemanager >> /usr/lib/R/library/base/R/Rprofile && \
    cat /tmp/Rprofile.packagemanager >> /etc/R/Rprofile.site && \
    rm /tmp/Rprofile.packagemanager

# metacheck from that checkout, built as install_github() would build it.
RUN --mount=type=bind,from=metacheck-src,target=/tmp/metacheck-src,rw \
    Rscript -e "remotes::install_local('/tmp/metacheck-src', \
        dependencies = FALSE, upgrade = 'never', build_vignettes = FALSE); \
      library(metacheck); cat('metacheck', as.character(packageVersion('metacheck')), '\n')"

# Modules installed from GitHub, as the SURF server's metacheck_modules: the
# TU/e data manager check, which the website's /datamanager/ page runs.
ENV METACHECK_MODULES_DIR=/opt/metacheck-modules
RUN mkdir -p "$METACHECK_MODULES_DIR" && \
    Rscript -e "metacheck::module_install('Lakens/tue_datamanager_check'); print(metacheck::module_installed())"

# The paper report app, the web interface (with the app's bibr client and
# list of checks that may use the language model, as on the SURF server) and
# the website.
COPY --from=surf /app/ /srv/metacheck-app/
COPY --from=surf /api/api.R /api/worker.R /api/psyarxiv_reports.R /api/notify.R \
     /app/bibr_client.R /app/llm_modules.R /srv/metacheck-api/
# metacheck's API helper code and repository check app, which the web
# interface uses and which are not part of the installed package (as the SURF
# server's fetch-api-helpers.sh takes them).
COPY --from=metacheck-src /inst/plumber/utils /srv/metacheck-api/metacheck-plumber/utils
COPY --from=metacheck-src /inst/app/shiny_app_repocheck /srv/metacheck-api/metacheck-repocheck
COPY --from=surf /site/ /srv/metacheck-site/
COPY nginx.conf /etc/nginx/conf.d/metacheck.conf
COPY --chmod=755 start.sh /usr/local/bin/start.sh

# Settings the app and the web interface read (see app/app.R and api/ in
# surf-research-cloud). The lightest installation: PDFs to TU/e's GROBID
# server, and to metacheck's server on SURF Research Cloud when that one does
# not answer (METACHECK_CONVERT_BACKUP); no language model. The installer's
# .env (see compose.yaml) adds the
# GROBID container (GROBID_LOCAL_URL and METACHECK_GROBID_URL), Ollama
# (OLLAMA_BASE_URL) or the user's Mistral key (MISTRAL_API_KEY).
ENV METACHECK_LOCAL=true \
    METACHECK_GROBID_URL=https://grobid.hti.ieis.tue.nl \
    METACHECK_CONVERT_BACKUP=surf \
    METACHECK_SANDBOX=process \
    METACHECK_API_JOBS=/var/lib/metacheck-api/jobs \
    METACHECK_API_WORKERS=2 \
    METACHECK_LLM_MODEL=qwen3.5:4b

EXPOSE 3838

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -sf -o /dev/null http://localhost:3838/api/health || exit 1

# -g: a stop signal (docker stop, Ctrl+C) reaches every program too.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/usr/local/bin/start.sh"]
