# Codex Usage Bar

A tiny macOS menu-bar app that displays local Codex usage from `~/.codex`.

The menu bar shows a plain percentage: current 5-hour usage when available, otherwise weekly usage. The tooltip and dropdown identify the usage window.

The dropdown shows the current 5-hour usage window, weekly usage, estimated dollars spent today, estimated dollars spent over the last 30 days, token counts, call counts, latest model, and reset times.

## How It Works

Codex writes thread metadata to `~/.codex/state_5.sqlite`. This app queries that database for recent rollout JSONL files, then parses `event_msg` records whose payload type is `token_count`.

Usage windows come from the latest Codex-provided `rate_limits` object for the `codex` limit (or older records without a limit ID). Windows are identified by their reported duration: 300 minutes for 5-hour usage and 10,080 minutes for weekly usage. Weekly-only plans can report their weekly window in `primary`.

The state database is opened read-only with SQLite directly, so large thread indexes do not stall on subprocess output.

Spend is estimated from each turn's `last_token_usage`:

```text
uncached input * input price + cached input * cached price
+ cache-write input * cache-write price + output * output price
```

Prices are API-equivalent estimates, not your ChatGPT subscription invoice. Defaults were verified on October 10, 2026 and include GPT-6 Astra, GPT-6.1 Sol, GPT-6 Sol, GPT-6 Luna, and updated GPT-5.6 rates alongside historical Codex models. They use published standard short-context rates; override them for long contexts, Fast/Ultrafast processing, regional surcharges, or custom pricing. Models without a configured price contribute tokens and calls but no estimated cost.

`cacheWriteInputPerMillion` is optional. If omitted in a custom price, cache-write tokens use the regular input rate. Cache-write tokens are excluded from regular input to avoid counting them twice.

Sources: [OpenAI API pricing](https://developers.openai.com/api/docs/pricing), [GPT-5.2-Codex](https://developers.openai.com/api/docs/models/gpt-5.2-codex), [GPT-5.1-Codex Mini](https://developers.openai.com/api/docs/models/gpt-5.1-codex-mini).

## Configure

Optional config path:

```text
~/.config/codex-usage-bar/config.json
```

Example:

```json
{
  "codexHome": "~/.codex",
  "refreshIntervalSeconds": 60,
  "leaderboardURL": "https://codex-usage-leaderboard.evanss.workers.dev",
  "leaderboardToken": "optional-worker-secret",
  "leaderboardTeamId": "friends",
  "leaderboardUserId": "optional-fixed-user-id",
  "leaderboardDisplayName": "Optional Display Name",
  "modelPrices": {
    "gpt-6.1-sol": {
      "inputPerMillion": 2.0,
      "cachedInputPerMillion": 0.1,
      "outputPerMillion": 10.0,
      "cacheWriteInputPerMillion": 2.5
    }
  }
}
```

Environment variables:

```sh
CODEX_USAGE_CODEX_HOME=~/.codex \
CODEX_USAGE_REFRESH_SECONDS=60 \
swift run
```

Use `CODEX_USAGE_CONFIG=/path/to/config.json` for a custom config file.

The friends leaderboard is enabled by default against the bundled Worker URL and shared Worker token. The app creates a stable local user ID on first launch and uses the Codex account name from local auth claims as the display name when available. Override the values below only when testing or pointing at another Worker.

Each friend publishes their own token counts and cost estimates. `—` means the estimate is unavailable: the cost field is missing, or the friend reported zero cost despite consuming tokens. Older apps can report zero for models missing from their pricing table; that friend needs updated pricing and a refresh. The leaderboard does not include their models or input/output breakdown, so another viewer cannot recalculate the estimate from total tokens alone.

Optional leaderboard environment variables:

```sh
CODEX_USAGE_LEADERBOARD_URL=https://codex-usage-leaderboard.evanss.workers.dev \
CODEX_USAGE_LEADERBOARD_TOKEN=your-worker-secret \
CODEX_USAGE_LEADERBOARD_TEAM_ID=friends \
CODEX_USAGE_LEADERBOARD_USER_ID=evans \
CODEX_USAGE_LEADERBOARD_DISPLAY_NAME=Evans \
swift run
```

## Run

```sh
swift run
```

## Test

```sh
swift test
```

## Build the macOS App

```sh
scripts/package_app.sh
open "dist/Codex Usage Bar.app"
```

## Build a Release Zip

```sh
scripts/release_zip.sh
```

This creates:

```text
dist/Codex Usage Bar.zip
```

## Auto Updates

The app uses Sparkle for updates and includes a "Check for Updates..." menu item.

The appcast is hosted directly in this repo:

```text
https://raw.githubusercontent.com/evansliaudet/codex-stats-viewer/main/releases/appcast.xml
```

The Sparkle public key is already in `Info.plist`. The private key is stored in this Mac's Keychain under the `codex-usage-bar` Sparkle account.

Manual release flow:

```sh
scripts/release_zip.sh
mkdir -p releases
cp "dist/Codex Usage Bar.zip" "releases/CodexUsageBar-0.1.0.zip"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account codex-usage-bar \
  --download-url-prefix "https://raw.githubusercontent.com/evansliaudet/codex-stats-viewer/main/releases/" \
  releases
```

Commit and push `releases/appcast.xml` and the versioned zip in `releases/`.

Fully automated release flow:

```sh
scripts/publish_release.sh 0.1.1 "Fix expired usage windows"
```

This bumps `Info.plist`, builds the app zip, updates Sparkle's appcast, commits, tags, pushes, and creates a GitHub Release with the zip assets.
