# GOD PREDITOR V7 · Time & Survival

Standalone static app based on this directory's original public `index.html`.
Serve the directory over HTTP(S); no build or npm dependencies are required.

## Data

`config.mjs` contains the existing browser-safe Supabase publishable key and table.
Never substitute a `service_role` or `sb_secret_` key. The app only performs GET
requests for confirmed, non-estimated rounds with real timestamps. It does not
change database settings, write rounds, or place wagers.

The original `URL` variable shadowed the browser's URL constructor, preventing
every request. Modules now use `globalThis.URL` for requests and CSV downloads.
The archive uses a fixed `source_seq` snapshot and exact signed integer keysets,
without offset pagination or the former 10,000-row limit. New rounds are checked
every 10 seconds. Future records hold back the polling cursor until eligible.

A complete archive is cached atomically in IndexedDB. Cache failure does not
stop the app. Cached records render immediately, then update incrementally; a
full reload runs on startup after six hours since the last complete archive
download. The two refresh controls update new rounds or reload the whole archive.
The CSV download includes the entire normalized archive, ordered by timestamp.

## Statistics

- Baseline: `1 - (1 - hits / rounds) ** horizon`, assuming independent rounds.
- Survival panel: the original empirical conditional frequency among completed
  observed hit-to-hit intervals, with `gap > distance` and
  `gap <= distance + horizon`. At least 20 comparable intervals are required.
  This is not a fitted Weibull model or a Kaplan–Meier estimator. Censored
  intervals are tracked separately; exclusion of unfinished intervals can bias
  the empirical estimate. Wilson bounds describe sampling uncertainty, not proof
  of a forecasting advantage.
- Intervals do not cross collection gaps exceeding five minutes or duplicate
  timestamps. An unobserved interval start is not treated as a known drought.
  Inputs older than three minutes suspend the current Survival estimate.
- Minute/second rankings aggregate all hours and days. They are descriptive,
  selected on the same archive, and do not validate repeatable future times.
- Chronological 70/30 testing measures a constant one-round baseline using Brier
  score. It does not validate Survival or the selected multi-round horizon.

Run checks with:

```sh
node --test god-preditor-v7-time-survival/tests/*.test.mjs
```

The original V7 visual design is retained. Parsing, statistics and persistence
are separate modules so data failures and model edge cases can be tested.
