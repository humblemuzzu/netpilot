<p align="center">
  <img src="docs/icon.png" alt="NetPilot app icon" width="128">
</p>

<h1 align="center">NetPilot</h1>

**A macOS menu bar app that shows how healthy your connection really is, explains why when it isn't, and fixes the most common cause of Wi-Fi stutter.**

NetPilot watches latency, packet loss, jitter and signal strength live, tells you in plain English what is wrong ("Weak signal is the likely cause. Move closer to the router."), ranks your saved Wi-Fi networks, and can switch to a better one or fail over between links without you touching System Settings.

<p align="center">
  <img src="docs/status.png" alt="NetPilot status tab" width="320">
  &nbsp;&nbsp;
  <img src="docs/networks.png" alt="NetPilot networks tab" width="320">
</p>

<sub>Screenshots use sample data.</sub>

## Why

Public and shared Wi-Fi (hotels, cafés, co-working spaces) fails in ways macOS does not surface: a network that is "connected" but dropping packets, a stronger network sitting unused one room over, or periodic latency spikes that make calls and games stutter.

The last one has a known cause. **AWDL** is the radio protocol behind AirDrop, Handoff and Sidecar. It pulls the Wi-Fi card off-channel roughly twice a second, which shows up as regular latency spikes. NetPilot can keep AWDL down and re-lower it whenever macOS brings it back.

## Features

- **Smart DNS.** On every network it races the network's own resolver against Cloudflare, Google, Quad9 and OpenDNS, then uses the fastest reliable one with a working backup. It steps aside for Wi-Fi sign-in pages, networks that intercept DNS, and IPv6-only networks, remembers each network's choice, and re-checks itself. See [DNS policy](#dns-policy).
- **Wi-Fi sign-in handling.** Detects captive portals the moment you join and when a hotel session expires mid-stay, puts DNS back on the network's own server so the page can load, and gives you a one-click **Sign in**. Shows the session time left on networks that publish it (RFC 8908).
- **Live latency graph.** Full-width, colour-coded green / amber / red by value, with a 100 ms reference line. Hover to scrub back in time.
- **Plain-English diagnosis that names the layer.** Tells you whether packets are lost between your Mac and the router ("the Wi-Fi is congested", "weak signal") or on the venue's internet line ("your Wi-Fi is fine"), and only claims loss when the evidence is statistically solid.
- **Stutter fix (AWDL control).** One toggle. A small root helper keeps `awdl0` down and re-lowers it after reconnects and sleep/wake.
- **Network ranking.** Scores your saved Wi-Fi networks on signal, band, channel congestion and gateway latency, with the reason for each.
- **One-click join.** Joins a saved network directly. If macOS needs the password, the helper reads it from the System keychain.
- **Per-link measurement.** Probes every active interface (Wi-Fi, iPhone USB tethering, Ethernet) independently, and can run a real download test on each.
- **Automatic failover.** Optionally reorders network services to the healthier link after two consecutive bad readings.
- **Idle-aware auto-switching.** Optionally moves to a better Wi-Fi network, but only when nothing is using the connection (see [Auto-switch behaviour](#auto-switch-behaviour)).
- **Menu bar status.** A pulse icon that turns into a warning triangle when the connection degrades.

## How it works

```
NetPilot.app  (SwiftUI MenuBarExtra, runs as your user, no root)
├── events    SCDynamicStore → network changes, DHCP resolvers, manual DNS (no polling)
├── internet  TCP handshake to 1.1.1.1:443 and 8.8.8.8:443, bound to the
│             primary interface, every 2 s (native sockets, 1 s timeout)
├── router    ICMP echo to the default gateway every 2 s (unprivileged socket)
├── radio     CoreWLAN → RSSI, noise, SNR, channel, link rate
├── portal    captive.apple.com probe on join, every 60 s, and on outages
├── DNS       raw DNS queries to each candidate resolver; writes the winner
│             with networksetup -setdnsservers (admin, no password prompt)
├── traffic   netstat -ib + lsof → throughput and open connections (every 3 s)
├── ranking   roamr watch --json → scored saved networks (optional dependency)
└── requests  writes /usr/local/etc/netpilot/{awdl_off, request.txt}
                          │
                          ▼
netpilotd     (root LaunchDaemon, ~120 lines of bash)
├── every 2 s  keeps awdl0 / llw0 down while the awdl_off flag exists
└── on request  join an SSID using the stored keychain password,
                or reorder network services
```

Key design decisions:

- **The UI never runs as root.** Only the helper does, and the helper is a short shell script so it can be audited in one sitting.
- **Probes are bound to each interface** (`IP_BOUND_IF`), so "Wi-Fi vs iPhone hotspot" is measured, not guessed.
- **Internet latency is TCP connect time**, not ICMP. Many cafés drop ping to the internet entirely. The 1 s timeout matches TCP's first SYN retransmit, so a lost packet is counted as lost instead of showing up as a fake 1000 ms sample.
- **The router is pinged separately.** Loss to the internet with a clean router means the venue's line; loss to both means the Wi-Fi link.
- **Loss is claimed only with evidence.** Over the last 90 probes (3 minutes) the app says "dropping packets" only when at least 3 probes failed and the 95% Wilson lower bound is at least 2%. A probe target that fails while the other works is that target's fault and is left out.
- **Jitter is RFC 3550 interarrival jitter** (the smoothed figure call apps use), not a standard deviation.
- **Latency shown is the median** of the last minute, so one spike doesn't define the number.
- **No Xcode project.** A single Swift package builds the app; a script assembles and ad-hoc signs the `.app` bundle.

### Diagnosis rules

| Condition | Headline |
|---|---|
| Captive portal not signed in | Sign-in needed |
| Last 3 probes all failed | Offline (says whether the router still answers) |
| Loss proven, router also losing | Dropping packets: weak signal or congested Wi-Fi |
| Loss proven, router clean | Dropping packets: the venue's internet line |
| Median latency ≥ 100 ms | Slow (names the router if it is the slow part) |
| Jitter > 30 ms | Choppy |
| RSSI ≤ −72 dBm or SNR < 20 dB | Weak signal |
| Latency 40–100 ms | Good |
| Otherwise | Excellent |

## Requirements

- macOS 13 (Ventura) or later. Developed and tested on Apple silicon.
- Swift 5.9+ toolchain (Xcode 15 or the Command Line Tools)
- [roamr](https://github.com/sourabh-khot65/roamr), **optional**. Needed only for the Networks tab. Everything else works without it.
  ```sh
  brew install --cask sourabh-khot65/tap/roamr
  ```

## Install

```sh
git clone https://github.com/humblemuzzu/netpilot.git
cd netpilot

# 1. Build the app, install to /Applications, start at login
./Scripts/install-app.sh

# 2. Install the root helper (needed for the stutter fix, password-based joins and failover)
sudo ./Scripts/install-daemon.sh
```

The app works without step 2 in read-only mode: you still get the live graph, diagnosis, ranking and measurements. Anything that changes system state goes through the helper.

NetPilot is ad-hoc signed and not notarized. If macOS blocks the first launch, right-click the app in `/Applications` and choose **Open**.

To build without installing: `./Scripts/build-app.sh` produces `build/NetPilot.app`.

## Usage

Click the pulse icon in the menu bar.

| Tab | What it shows |
|---|---|
| **Status** | Signal, loss, jitter and router latency; band, channel, link rate and SNR; current traffic; toggles for Smart DNS, the stutter fix, automatic network switching and link failover |
| **DNS** | What Smart DNS chose and why, the servers in effect, and the last race: each resolver's typical time and how many queries it missed. **Test again** re-runs it |
| **Networks** | Saved networks ranked best-first, with band and the reason for the ranking. **Join** switches immediately |
| **Links** | Every active connection with live latency and a Primary marker. **Test speeds** runs a 2 MB download per link; **Prefer fastest** reorders services by the result |

### Auto-switch behaviour

Switching Wi-Fi networks drops every open TCP connection, so automatic switching is deliberately conservative:

1. Every 3 seconds it checks for **established connections** to remote hosts (loopback, Tailscale and Continuity traffic excluded) and for **throughput above 5 KB/s**.
2. If either is present, the switch is **held** and a prompt offers **Switch** or **Cancel**.
3. Only when the link is idle does a **10-second cancellable countdown** start.
4. After a switch there is a **5-minute cooldown**.

In practice, with a browser open the connection is rarely idle, so auto mode will usually wait for you to press Switch. That is intentional: it never trades a working session for a few milliseconds.

### Link failover

With two or more links up (for example Wi-Fi plus iPhone USB tethering), enabling **Fail over between links** reorders network services to the healthier link when the primary is worse than `max(80 ms, 1.8 × best alternative)` on two consecutive probes, or stops responding.

macOS sends each connection out one default route, so two links do **not** add their speeds together. What works:

| Goal | Possible | How |
|---|---|---|
| Both links connected at once | Yes | Wi-Fi and iPhone USB tethering coexist |
| Instant failover to the better link | Yes | Failover reorders service priority |
| Measure which link is faster | Yes | **Test speeds** |
| Add the two speeds together | Only with a TUN-based balancer | Out of scope; see [net-merge](https://github.com/net-merge/net-merge) |

## Project layout

```
Sources/NetPilot/
  main.swift         App entry point and menu bar scene
  AppModel.swift     State, network events, portal checks, roamr feed, switching and failover
  NetState.swift     SCDynamicStore watcher: primary service, router, DHCP and manual DNS
  Probe.swift        Native probes: TCP connect, raw DNS query, unprivileged ICMP echo
  Health.swift       Rolling link statistics, loss evidence, CoreWLAN radio readings
  SmartDNS.swift     Resolver race, decision, per-network memory and watchdog
  Portal.swift       Captive portal detection and the RFC 8908 session API
  Traffic.swift      Interface byte counters and open-connection count
  Views.swift        Panel, tabs and the diagnosis rules
  Components.swift   Latency graph, theme colours, shared controls
daemon/
  netpilotd.sh                   Root helper
  local.netpilot.daemon.plist    LaunchDaemon definition
Resources/
  Info.plist                     App bundle metadata (menu-bar-only, macOS 13+)
  AppIcon.icns                   App icon, generated by Scripts/make-icon.sh
  local.netpilot.app.plist       Login-item template, rendered by install-app.sh
Scripts/
  build-app.sh                   Release build and ad-hoc signed .app bundle
  install-app.sh                 Build, install to /Applications, start at login
  install-daemon.sh              Install and load the root helper (sudo)
  uninstall-daemon.sh            Remove the helper and restore AWDL (sudo)
  make-icon.sh / make-icon.swift Regenerate the app icon from its vector drawing
```

## Security model

- The app runs unprivileged. The helper runs as root as a LaunchDaemon (`local.netpilot.daemon`) and does exactly two things: enforce the AWDL flag, and execute requests.
- The app and helper communicate through files in `/usr/local/etc/netpilot`, which is owned `root:admin` and group-writable. **Any process running as an admin user can queue a request**, including joining a saved network or reordering services. This matches the access an admin already has through `networksetup`, but you should know the boundary.
- To join a network the helper reads that network's saved password from the System keychain and passes it to `networksetup`. The password is never written to disk, logged, or returned to the app.
- Probes open (and immediately close) TCP connections to `1.1.1.1` and `8.8.8.8`, ping your router, fetch `captive.apple.com`, and send small DNS queries to the resolvers being compared. Speed tests download 2 MB from `speed.cloudflare.com`. There is no telemetry.
- Smart DNS changes the DNS servers of the active network service through `networksetup`, which admin accounts may do without a password. It only ever writes to services it has changed itself or the current primary one, and puts them back to automatic when you move networks, turn Smart DNS off, or quit.
- The helper logs to `/var/log/netpilot.log`.

### DNS policy

macOS stores manual DNS per network *service* ("Wi-Fi"), not per Wi-Fi network, so a
setting made at one hotel follows you to the next. And macOS uses the list in order:
each lookup goes to the first server, is retried there, and only moves to the next
after about three seconds of silence. So Smart DNS treats DNS as something to decide
on every network, with the best server first and a working one second.

1. **On arrival, step aside.** Any override from the previous network is removed at
   once, so the new network's sign-in page works.
2. **Wait for the portal check.** If the network wants a sign-in, DNS stays on the
   network's own server until you are through.
3. **Rule out unsafe overrides.** If a query to an address that runs no DNS server
   gets an answer, the network intercepts all DNS and other servers would only be
   imitated. If the network's resolver synthesises IPv6 addresses (DNS64), public
   resolvers would break IPv4-only sites. Either way, the network's DNS is kept.
4. **Race.** The network's resolver, Cloudflare, Google, Quad9 and OpenDNS each get
   the same 24 queries at the same moment, one attempt each with a 1.2 s timeout.
5. **Score fairly on lossy networks.** Packet loss on the venue's line hits every
   resolver alike, so a resolver's misses only count against it when they are
   significantly above the most reliable resolver's (two-proportion z-test). The
   rest of the score is median plus a quarter of the 90th percentile.
6. **Prefer the network's own resolver on near-ties** (15% bias): it is on the LAN and
   points you at nearby CDN servers, which public resolvers that hide your subnet
   (Cloudflare, Quad9) often cannot.
7. **Don't flap.** A different server must be at least 20% and 8 ms better to
   replace the current choice. The second slot always goes to the next-best
   resolver from a different operator.
8. **Remember and re-check.** The choice is stored per network and applied as soon
   as you return. The race repeats every 20 minutes, and immediately if the server
   in use fails twice in a row on three consecutive checks.

Decisions are logged: `log show --last 1h --info --predicate 'subsystem == "local.netpilot"'`.

## Limitations

- **Saved networks only.** macOS gates Wi-Fi scanning behind Location permission, so NetPilot ranks the networks you already know rather than scanning on its own.
- **AWDL is enforced by polling** every 2 seconds, so a re-enable can survive for up to about 2 seconds.
- **While the stutter fix is on**, AirDrop, Handoff, Universal Control and Sidecar are unavailable. Turn the toggle off to restore them.
- **Smart DNS uses plain DNS.** Encrypted DNS needs a signed network extension or a configuration profile, which an ad-hoc signed app cannot install.
- **SSID needs roamr.** macOS hides the Wi-Fi name from apps without Location permission; NetPilot identifies networks by their configd profile ID instead, and shows the name when roamr provides it.

## Uninstall

```sh
sudo ./Scripts/uninstall-daemon.sh        # removes the helper and turns AWDL back on
launchctl bootout gui/$(id -u)/local.netpilot.app
rm -rf /Applications/NetPilot.app ~/Library/LaunchAgents/local.netpilot.app.plist
```

## Contributing

Issues and pull requests are welcome. Run `swift build` to check changes compile, and `./Scripts/build-app.sh` to produce a runnable bundle. Please keep the helper small: anything that runs as root should stay easy to read end to end.

## Credits

- [roamr](https://github.com/sourabh-khot65/roamr) (MIT): the network scoring engine and wire format this app consumes.
- [awdl-toggle](https://github.com/yay/awdl-toggle) (MIT): prior art for keeping AWDL down across route changes.
- [meterup/awdl_wifi_scripts](https://github.com/meterup/awdl_wifi_scripts): the launchd daemon pattern the helper follows.

## License

[MIT](LICENSE)
