# metacheck on your own computer

The website, web interface and paper report app of metacheck's SURF Research
Cloud server ([scienceverse/surf-research-cloud](https://github.com/scienceverse/surf-research-cloud)),
in Docker on your own computer. The lightest installation needs little memory
but sends some things to external servers; each part you add does more on your
own computer:

| Part | Without it | With it | Memory |
|---|---|---|---|
| metacheck (always) | | website, web interface, paper report app, and running a repository's code | 0.3 GB idle, 1.6 GB with two jobs at once |
| GROBID | a PDF is sent to TU/e's GROBID server (GDPR compliant) for conversion, or, when that server does not answer, to metacheck's server on SURF Research Cloud (the Netherlands); set `METACHECK_CONVERT_BACKUP=` in `.env` to never use the SURF server | PDFs are converted on your computer | 3.7 GB more |
| language model | the power check works without a model | Ollama on your computer (paragraphs stay on your computer), or Mistral (EU) with your own API key (paragraphs about statistical power are sent to Mistral) | Ollama: 3.5 GB, on a graphics card if you have one |

Memory measured with Docker Desktop on Windows (October 2026). Docker Desktop
on Windows gives Docker half of the computer's memory (on a Mac, see Docker
Desktop's Settings > Resources). So the lightest installation fits in the 4 GB
Docker gets on a computer with 8 GB of memory (not yet tried on one); with
GROBID, use a computer with 16 GB.

## Install

On Windows, run this in PowerShell:

```powershell
irm https://raw.githubusercontent.com/scienceverse/metacheck_platform_docker/main/install.ps1 | iex
```

The installer ([install.ps1](install.ps1)) asks whether to install Docker
Desktop, GROBID and Ollama (pressing Enter means no), and for a Mistral API key
(Enter skips it; you can add one later). It puts everything in a folder
`metacheck` in your user folder, with `start-metacheck.cmd` and
`stop-metacheck.cmd`, and starts metacheck.

On macOS and Linux, run this in a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/scienceverse/metacheck_platform_docker/main/install.sh | bash
```

The installer ([install.sh](install.sh)) asks the same questions. On macOS it
installs Docker Desktop and Ollama with [Homebrew](https://brew.sh), and the
start and stop files are `start-metacheck.command` and `stop-metacheck.command`
(double-click to run them). On Linux it installs Docker Engine and Ollama with
their own install scripts, and Ollama listens on Docker's network address
(172.17.0.1) only. The macOS and Linux installer has not been tested on those
systems yet.

By hand, on any system: install [Docker Desktop](https://www.docker.com/products/docker-desktop/) (on
Linux, Docker Engine) and start it. Put [compose.yaml](compose.yaml) in a new
folder, and next to it a file `.env` with your choices ([example.env](example.env)
lists them; an empty `.env` is the lightest installation). In that folder, run:

```bash
docker compose up
```

When the terminal shows `metacheck is ready`, open:

| Address | What |
|---|---|
| http://localhost:3838 | the website: a paper, a folder or an online repository |
| http://localhost:3838/metacheck/ | the paper report app (Shiny) |
| http://localhost:3838/researchbox/ | the ResearchBox check |
| http://localhost:3838/datamanager/ | the TU/e data manager check |
| http://localhost:3838/api/__docs__/ | the web interface, for your own code |

The terminal also says where PDFs are converted and which language model the
power check uses. Press Ctrl+C to stop. Reports are kept for one hour while
metacheck runs, and are gone when it stops. To get a newer version:
`docker compose pull`.

## Settings (`.env`)

- **GROBID on your computer:** the lines `COMPOSE_PROFILES=grobid`,
  `GROBID_LOCAL_URL=http://grobid:8070` and `METACHECK_GROBID_URL=http://grobid:8070`.
- **Ollama:** install [Ollama](https://ollama.com), run `ollama pull qwen3.5:4b`,
  set the environment variable `OLLAMA_CONTEXT_LENGTH` to `16384` before Ollama
  starts (as on the SURF server; see Ollama's FAQ), and add the line
  `OLLAMA_BASE_URL=http://host.docker.internal:11434`. On Linux (not tested
  yet), let Ollama accept connections from Docker with `OLLAMA_HOST=172.17.0.1`.
- **Mistral:** get an API key at [console.mistral.ai](https://console.mistral.ai/api-keys)
  and add the line `MISTRAL_API_KEY=` followed by the key. Mistral is used only
  when Ollama is not set up.

After changing `.env`, stop metacheck and run `docker compose up` again.

## Running the code of a repository

The reproducibility check runs a repository's R and Python code inside the
container (metacheck's `sandbox = "process"`), installing the packages it needs
first. The container is not a closed sandbox: the code can use the internet,
but it cannot reach the files on your computer.

## Build it yourself

```bash
docker build -t metacheck-platform .
# with a local copy of surf-research-cloud, or another metacheck branch:
docker build --build-context surf=../surf-research-cloud --build-arg METACHECK_REF=dev -t metacheck-platform .
```

Then set `METACHECK_IMAGE=metacheck-platform` in `.env` to use it.

GitHub builds the image for Intel/AMD and ARM (Apple Silicon) and publishes it
as `ghcr.io/scienceverse/metacheck_platform_docker` (`.github/workflows/build.yml`):
on every push to `main`, every Monday (with the newest commit of metacheck's
`dev` branch), and when the workflow is started by hand.
