# historyd

Overflow storage for chat-history backup segments. relayd keeps segments on its
own disk while it has room (`-history-min-free`) and sends them here when it
doesn't (see *History backup storage* in [`../../README.md`](../../README.md)).
historyd holds only opaque ciphertext under keyed-hash names: it can't tell
whose backup a blob is, and it never sees the key that names them.

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `-addr` | `:9479` | Listen address. |
| `-dir` | `/var/lib/historyd` | Blob directory (created `0700`; files `0600`, written atomically). |
| `-secret-file` | (required) | Secret shared with relayd's `-history-remote-secret-file`, at least 32 bytes. |
| `-tls-cert`, `-tls-key` | (none) | Serve HTTPS with this certificate; re-read within a minute of the file changing. Plain HTTP only when both are empty (tests). |
| `-max-bytes` | `10737418240` (10 GiB) | Cap on stored bytes; `0` = only the free-disk floor. |

Writes get `507` once they would pass `-max-bytes` or leave less than 1 GiB free
on the filesystem.

## API

Every request carries
`Relay-History-Auth: <unix seconds>.<hex HMAC-SHA256(secret, METHOD "\n" PATH "\n" UNIX "\n" hex SHA-256(body))>`.
A bad MAC or a timestamp more than 5 minutes off gets `401`. Bodies are capped
at 2 MiB (`413`). `{key}` is 64 lowercase hex characters.

| Method & path | Response |
|---|---|
| `PUT /v1/blob/{key}` | raw body (1 byte to 2 MiB) → `204`; replaces. `400` bad key or empty body, `507` full. |
| `GET /v1/blob/{key}` | → `200` raw bytes, or `404`. |
| `DELETE /v1/blob/{key}` | → `204`, whether or not it existed. |
| `GET /v1/blobs` | → `{blobs: [{key, modified}]}` (`modified` in unix seconds), for relayd's orphan sweep. |
| `GET /health` | → `{freeBytes, usedBytes}`; `freeBytes` is what it will still accept. |

## Deploy (TURN box)

```sh
openssl rand -hex 32 > history.secret   # same file content on both boxes, mode 0600
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o historyd ./cmd/historyd
```

Create a system user (`useradd --system --no-create-home --shell /usr/sbin/nologin historyd`),
install the binary as `/usr/local/bin/historyd` and the secret as
`/etc/historyd/secret` (`root:historyd`, `0640`). It can reuse coturn's copy of
the `turn.relaymsg.app` certificate (`/etc/turnserver-tls/`; adjust the file
names below to match) if the `historyd` user can read it.

```ini
# /etc/systemd/system/historyd.service
[Unit]
Description=Relay history backup overflow store
After=network-online.target
Wants=network-online.target

[Service]
User=historyd
Group=historyd
ExecStart=/usr/local/bin/historyd -addr :9479 -dir /var/lib/historyd \
    -secret-file /etc/historyd/secret \
    -tls-cert /etc/turnserver-tls/fullchain.pem -tls-key /etc/turnserver-tls/privkey.pem \
    -max-bytes 10737418240
StateDirectory=historyd
StateDirectoryMode=0700
Restart=always
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Firewall: only the API box may reach it. Allow the port from that one address
and nothing else, e.g. `ufw allow from <API box IP> to any port 9479 proto tcp`.

Then on the API box run relayd with
`-history-remote-url https://turn.relaymsg.app:9479 -history-remote-secret-file <path to the secret>`.
