# reMarkable Support Dump

Utilities for collecting diagnostic data from a reMarkable tablet and (optionally) serving the result over HTTP.

- `rm-support.sh` creates a tarball (`rm-debug-*.tgz`) with support-safe system information.
- `rm-support-http` is a minimal HTTP server that lists and serves bundles.
- `install.sh` is a one-shot helper that downloads both tools, runs them, and cleans up.

## One-shot usage

Run the command below as `root` on the reMarkable (for example via `ssh -tt root@10.11.99.1 'wget ... | sh'` to get an interactive prompt):

```sh
wget https://raw.githubusercontent.com/mikalv/remarkable-dump/main/install.sh -O- | sh
```

The installer:

- downloads `rm-support.sh` and `rm-support-http`
- runs `rm-support.sh`, producing `rm-debug-*.tgz`
- starts the HTTP server and prints one highlighted download link (plus an optional "latest" link)
- keeps the HTTP server alive for a short window, then stops it and removes the temporary files automatically

Helpful environment variables:

- `RAW_BASE` -- override the base raw URL (forks, branches, testing)
- `RM_HTTP_BIND` -- listen address for the temporary server (default `0.0.0.0:8080`)
- `RM_HTTP_DIR` -- directory the server should expose (default is where the bundle landed)
- `RM_HTTP_IFACES` -- interface names to probe for an IPv4 address suggestion (`usb0 wlan0 eth0`)
- `INSTALL_DIR` -- force a specific working directory instead of a new temp folder
- `KEEP_INSTALL=1` -- skip cleanup so the downloaded files remain on disk
- `USB_DOWNLOAD_HOST` -- primary host used in the printed URL (default `10.11.99.1`)
- `PREFER_DEVICE_IP=1` -- prefer the detected interface IP over `USB_DOWNLOAD_HOST` in the URL
- `SCRUB_TIMEOUT` -- seconds to keep the HTTP server alive before automatic cleanup (default `300`)

After printing the download link the script keeps the HTTP server running for `SCRUB_TIMEOUT` seconds (5 minutes by default) before shutting it down and cleaning up. You can stop it early with `Ctrl+C` or `kill <pid>`. Without an interactive terminal the countdown still runs, so simply fetch the bundle and wait for the timeout (or power-cycle the device to stop it sooner).

## Manual usage

If you keep the tools (`KEEP_INSTALL=1`) or build them yourself:

1. Run the collector:

   ```sh
   sh /path/to/rm-support.sh
   ```

2. Serve the resulting bundles (optional):

   ```sh
   RM_HTTP_DIR=/home/root /path/to/rm-support-http
   ```

   The server listens on `0.0.0.0:8080`. Adjust with:

   ```sh
   RM_HTTP_BIND=127.0.0.1:8000 RM_HTTP_DIR=/home/root /path/to/rm-support-http
   ```

## Building

The project is written in Rust. To create a static musl build for ARM64 (reMarkable 2):

```sh
cargo build --release --target aarch64-unknown-linux-musl
```

The binary will be placed in `target/aarch64-unknown-linux-musl/release/rm-support-http`.
