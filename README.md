# build-scripts

Server bootstrap tooling.

## ubuntu-server-setup.sh

Interactive Ubuntu server configuration tool for dev / test / production boxes.

On launch it prints a configuration overview (hostname, interfaces, gateway, DNS,
Docker status, SSH keys) then shows a menu:

1. Modify IP address / subnet / gateway (via netplan)
2. Modify DNS servers (via netplan)
3. Update hostname
4. Install essential networking tools (net-tools, dnsutils, tcpdump, nmap, etc.)
5. Install Docker & Docker Compose (official convenience script)
6. Add an SSH public key (to the invoking user's account and root)
7. Set up insecure Docker registries (`/etc/docker/daemon.json`)

Must be run as root (`sudo`). Netplan edits are backed up before being changed.

## Running it on a server (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/iprimo/build-scripts/main/bootstrap.sh -o bootstrap.sh && sudo bash bootstrap.sh
```

This downloads the small `bootstrap.sh` loader, which then fetches the
**latest** `ubuntu-server-setup.sh` from this repo and runs it with a real
terminal attached (menu prompts work correctly — don't pipe straight into
`bash` or stdin gets eaten by the pipe).

Keep `bootstrap.sh` around locally (e.g. in `~/bin/setup-server`) and just
re-run it whenever you want the newest version of the full script — it always
pulls fresh from GitHub.

## Updating the script

Edit `ubuntu-server-setup.sh`, commit, push to `main`. The next time anyone
runs `bootstrap.sh` they get the update automatically — no redistribution
needed.
