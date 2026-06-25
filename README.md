# Codex Usage Bar

A tiny macOS menu-bar app that displays local Codex usage from `~/.codex`.

The menu bar shows:

```text
5h <percent> | W <percent>
```

The dropdown shows the current 5-hour usage window, weekly usage, estimated dollars spent today, estimated dollars spent over the last 30 days, token counts, call counts, latest model, and reset times.

## How It Works

Codex writes thread metadata to `~/.codex/state_5.sqlite`. This app queries that database for recent rollout JSONL files, then parses `event_msg` records whose payload type is `token_count`.

Usage windows come from the latest Codex-provided `rate_limits` object:

- `primary`: current 5-hour window
- `secondary`: weekly window

Spend is estimated from each turn's `last_token_usage`:

```text
uncached input * input price + cached input * cached price + output * output price
```

Prices are API-equivalent estimates, not your ChatGPT subscription invoice. Defaults use OpenAI's published standard short-context API rates for the included models. Override them if you use another tier, long-context pricing, priority processing, or custom pricing.

Source: https://platform.openai.com/docs/pricing

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
  "modelPrices": {
    "gpt-5.5": {
      "inputPerMillion": 5.0,
      "cachedInputPerMillion": 0.5,
      "outputPerMillion": 30.0
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

## Run

```sh
swift run
```

## Build the macOS App

```sh
scripts/package_app.sh
open "dist/Codex Usage Bar.app"
```
