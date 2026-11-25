# Aviary

A custom Phoenix LiveView UI in front of a self-hosted Jellyfin media server. Built to replace the multi-app experience (request in Jellyseerr, watch in Jellyfin, check on a download in Radarr) with a single deliberate interface where every state worth knowing about lives on the item itself.

Design language: editorial cabinet — Fraunces display serif, Instrument Sans for UI, a day/night palette swap with a single oxblood accent. Restraint as the design choice.

Aviary is deployed alongside the rest of the home media stack ([depot](https://github.com/pachun/depot)) but iterates here in its own repo so the deploy infrastructure and the app code aren't tangled in one history.

## Running locally

Aviary expects a reachable Jellyfin instance with an API key. The dev loop runs on your laptop and points at Jellyfin over Tailscale — same URLs that work from your browser work from `mix phx.server`.

1. **Install Elixir + the Phoenix generator** (once per machine).
   ```
   sudo pacman -S elixir
   mix archive.install hex phx_new
   ```

2. **Fetch project deps.**
   ```
   mix deps.get
   ```

3. **Set up your env file.**
   ```
   cp .env.local.example .env.local
   ```
   Then edit `.env.local` and fill in the two variables (see below). `.env.local` is gitignored — credentials never reach the repo.

4. **Start the dev server via `bin/dev`.**
   ```
   bin/dev
   ```
   This sources `.env.local` and starts `mix phx.server` with the env populated. Visit http://localhost:4000.

## Environment variables

| Variable | What it is | Where to get it |
|---|---|---|
| `JELLYFIN_URL` | Base URL of your Jellyfin server, no trailing slash. From your laptop on the tailnet, use the Tailscale HTTPS URL — e.g. `https://framework-depot.<tailnet>.ts.net:8096`. Matches what `configure.sh`'s summary prints in depot. | Run `tailscale serve status` on the box hosting Jellyfin, or copy from depot's `configure.sh` summary output. |
| `JELLYFIN_API_KEY` | Jellyfin API token used for catalog reads + poster URLs. | Jellyfin admin → Dashboard → API Keys → "+" → name it `aviary`. Reusing the Sonarr key works but gives you no audit trail per integration. |

In production, depot's `configure/aviary/configure.sh` sets the same variables in the container's env. Application code reads them identically in both environments via `Application.fetch_env!(:aviary, :jellyfin_url)`.
