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
- waits for you to press Enter, then stops the server and removes the temporary files

Helpful environment variables:

- `RAW_BASE` -- override the base raw URL (forks, branches, testing)
- `RM_HTTP_BIND` -- listen address for the temporary server (default `0.0.0.0:8080`)
- `RM_HTTP_DIR` -- directory the server should expose (default is where the bundle landed)
- `RM_HTTP_IFACES` -- interface names to probe for an IPv4 address suggestion (`usb0 wlan0 eth0`)
- `INSTALL_DIR` -- force a specific working directory instead of a new temp folder
- `KEEP_INSTALL=1` -- skip cleanup so the downloaded files remain on disk

When no interactive terminal is available (for example `ssh root@host 'wget ... | sh'` without `-t`), the script leaves the HTTP server running in the background and prints a `kill <pid>` command you can run later (or just reboot) once the download is complete.

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
