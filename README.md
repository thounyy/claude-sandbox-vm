# Isolated VM for Claude Code (and other coding agents)

A small script that creates a KVM virtual machine on your Linux laptop where Claude Code runs, builds and tests your project, with **one shared folder** from your host and your normal editor connected over SSH.

The point: an agent that runs commands without asking is far less risky when it lives in a VM that only sees one project folder, instead of your whole user session (SSH keys, cloud credentials, other projects).

## How it works

```
Host (Fedora / Ubuntu / Manjaro)
 ├─ libvirt + QEMU/KVM
 ├─ ~/working-directory/myproject ──── virtiofs (read-write) ───┐
 └─ VS Code ──── SSH ────┐                                      │
                         ▼                                      ▼
                        VM (own kernel)  ~/working-directory/ (the shared folder)
                         ├─ Claude Code CLI + editor server
```

- Everything the agent runs (builds, tests, package installs) happens **inside the VM**.
- The VM has its own kernel, which is a stronger boundary than a container or the Claude Code Bash sandbox.
- Giving an agent access to a *host* Docker daemon is effectively giving it root on the host.

## Prerequisites

### Host

| Need | Details |
|---|---|
| Linux with KVM | Hardware virtualization (Intel VT-x / AMD-V) enabled in firmware. `ls /dev/kvm` must work. |
| `sudo` | The script calls `sudo` for libvirt and for the disk image. Run it as a normal user, never as root. |
| bash 4.4+, `ssh`, `ssh-keygen`, `sha256sum`, `awk`, `sed` | Standard on all three distros. |
| libvirt, QEMU, `virt-install`, `virtiofsd` | See the table below. `virt-install` must support `--cloud-init` and `--osinfo` (version 4.0 or newer) **(verify)**. |
| ~10 GB RAM and ~20 GB disk free (minimum) | Defaults: 8 GB RAM, 4 vCPUs, 100 GB thin-provisioned disk (only the used space is stored). |
| IDE (optional) | VS Code + *Remote - SSH*, or VSCodium + *Open Remote - SSH* (Open VSX). |

Install libvirt and friends **(verify the package names for your release)**:

| Distro | Packages |
|---|---|
| Fedora | `sudo dnf group install virtualization` and `sudo dnf install virtiofsd` |
| Ubuntu | `sudo apt install qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst virtiofsd` |
| Manjaro / Arch | `sudo pacman -S qemu-full libvirt virt-install dnsmasq virtiofsd` |

Then start libvirt and make sure the `default` network is up:

```bash
sudo systemctl enable --now libvirtd        # on newer setups with modular daemons, enable virtqemud.socket,
                                            # virtnetworkd.socket, virtstoraged.socket and virtnodedevd.socket instead
sudo virsh net-start default                # ignore "already active"
sudo virsh net-autostart default
sudo virsh net-list --all                   # "default" should be active
```

If the `default` network does not exist (can happen on Arch/Manjaro), define it from libvirt's shipped XML, typically `/usr/share/libvirt/networks/default.xml` **(verify path)**: `sudo virsh net-define <file>`.

> Depending on your distro and group membership, plain `virsh` (no sudo) may talk to a per-user libvirt instance that cannot see this VM (on Fedora it usually works out of the box). Test with `virsh list --all` after the install: if `claude-vm` is listed, use plain `virsh`. Otherwise use the `vsh` alias from "Daily use", or `export LIBVIRT_DEFAULT_URI=qemu:///system` in your shell.

### Guest image

Download a **cloud image** (qcow2) yourself and verify it. Do not use an installer ISO.

- Fedora: *Fedora Cloud Base (Generic)* qcow2 from <https://fedoraproject.org/cloud/download>. This is the default setup.
- Ubuntu: the LTS cloud image (`...-server-cloudimg-amd64.img`) from <https://cloud-images.ubuntu.com>. Set `OSINFO=ubuntu-lts-latest` **(verify the name with `virt-install --osinfo list`)**.

Verify the download against the checksum file published next to it (and its signature if you can), then put the checksum in `GUEST_IMAGE_SHA256`.

## Quick start

```bash
git clone <this repo> && cd <this repo>
cp config.env.example config.env
$EDITOR config.env                 # set GUEST_IMAGE and SHARE_DIR at minimum
./setup-vm.sh                      # or: bash setup-vm.sh
```

Then:

1. Connect your editor to the SSH host `claude-vm` (VS Code: *Remote-SSH: Connect to Host...*), open the project under the shared folder, and install the **Claude Code** extension on the SSH side.
2. Sign in to Claude inside the VM (see *Claude login* below).
3. Take a snapshot (see *Snapshots*).

The script prints `PASS`/`FAIL` for Claude Code and shared-folder write access at the end.

## What the script does

`./setup-vm.sh up` (the default) does, in order:

1. **Checks** (before changing anything): config values, required commands, `/dev/kvm`, that the VM does not already exist, that the libvirt network is active, IP forwarding, Docker on the host (warning only), shared folder sanity (it refuses `$HOME` and `/`), `virtiofsd`, image checksum.
2. Creates an SSH key for the VM if missing (`~/.ssh/claude-vm_ed25519`, no passphrase: it only opens this VM).
3. Copies the image into libvirt's images directory and grows it to `DISK_GB`.
4. Writes a cloud-init file: a user with **your host uid**, your SSH public key, `git`, the virtiofs mount, and Claude Code.
5. Runs `virt-install` to create and boot the VM.
6. Waits for an IP, writes a `Host claude-vm` block in `~/.ssh/config` (replaced on re-creation, old file kept as `config.bak`), waits for cloud-init, and runs the checks.

`./setup-vm.sh destroy` deletes the VM, its disk and its snapshots and removes the SSH block. It never touches the shared folder. The SSH key is kept.

## Settings (`config.env`)

| Variable | Default | Notes |
|---|---|---|
| `GUEST_IMAGE` | *(required)* | Path to the qcow2 cloud image. |
| `SHARE_DIR` | *(required)* | One host project folder, or `none` for no shared folder. |
| `GUEST_IMAGE_SHA256` | empty | Strongly recommended. |
| `VM_NAME` | `claude-vm` | Also the SSH alias. |
| `VM_USER` / `VM_UID` | your user / uid | Keep `VM_UID` equal to your host uid (see *Troubleshooting*). |
| `RAM_MB`, `VCPUS`, `DISK_GB` | 8192, 4, 100 | A reasonable choice is half your RAM and threads. |
| `GUEST_MOUNT` | `/home/<user>/Dev` | Where the share appears in the VM. |
| `OSINFO` | `fedora-unknown` | `virt-install --osinfo list` shows valid names. |
| `NETWORK`, `URI`, `IMAGES_DIR` | `default`, `qemu:///system`, `/var/lib/libvirt/images` | |
| `SSH_KEY` | `~/.ssh/<VM_NAME>_ed25519` | |
| `CLAUDE_CMD` | vendor install script | Run as your user in the VM on first boot. Must not contain single quotes. **(verify against the vendor's current install docs)** |

## Daily use

Typing `sudo virsh -c qemu:///system` every time is tedious. Add an alias to your `~/.bashrc` (or `~/.zshrc`) and reopen your terminal:

```bash
alias vsh='sudo virsh -c qemu:///system'
```

This is only needed if plain `virsh list --all` does not show your VM (see the note in the prerequisites); if it does, just use `virsh` instead of `vsh` below. Without the alias, replace `vsh` with `sudo virsh -c qemu:///system`.

```bash
vsh start claude-vm        # start (the VM does not autostart)
vsh shutdown claude-vm     # stop
```

Run Claude, builds and tests **in the VM window**. Use a normal local editor window on the host to read and review changes.

### Claude login

Inside the VM (editor terminal), run `claude` then `/login`. It prints a URL: open it in your host browser, sign in, and paste the code back into the terminal. The extension's *Sign in* button may also work through VS Code's port forwarding **(not verified)**. Alternatively put a dedicated, spend-limited API key in the VM's `~/.claude/settings.json` under `"env": { "ANTHROPIC_API_KEY": "..." }`.

Do not copy credentials from your host into the VM.

### Snapshots

A VM with a virtiofs share cannot be snapshotted while running, so shut it down first:

```bash
vsh shutdown claude-vm      # wait until: vsh domstate claude-vm  ->  shut off
vsh snapshot-create-as claude-vm clean-base
vsh start claude-vm
```

Revert: shut down, then `vsh snapshot-revert claude-vm clean-base`. List and delete with `snapshot-list` and `snapshot-delete`. Snapshots live in the same disk image: they are an undo button, not a backup. They do **not** revert the shared folder, which lives on the host. Commit with git before risky runs.

## Security model

**What it gives you:** a separate kernel; the agent only sees the VM's disk and the one shared folder; no host Docker socket (the VM has none), no host SSH keys or cloud credentials (the VM never sees them); `ForwardAgent no`.

**What it does not give you:**

- **The shared folder is writable by the agent.** Anything in it can be modified, including files that run later on your host: `.git/hooks`, `package.json` scripts, `node_modules/.bin`, `.vscode/tasks.json`, `.envrc`. Run git, builds and tests inside the VM, and review diffs before running anything from that folder on the host. For stricter separation, use `SHARE_DIR=none`, clone the repo inside the VM, and move code with git (host pulls from the VM over SSH, pushes with its own credentials).
- **Share one project, not your home directory.** Keep secrets out of the shared folder.
- **The network is open by default.** The VM can reach the whole internet, so anything the agent can read can be sent out. Restrict egress if that matters to you (for example with a host firewall or an allow-list proxy). That is not included here.
- **Credentials in the VM** (Claude login, any git token) are readable by the agent. Use tokens scoped to a fork or a single repo.
- Provisioning runs vendor install scripts piped to a shell, and the VM user has passwordless sudo *inside the VM*. That is a convenience trade-off for a disposable VM.
- A VM reduces risk, it does not make it zero (hypervisor and virtiofs bugs exist).

## Troubleshooting

**The VM has no internet** (it can ping `192.168.122.1` but not `1.1.1.1`). Run these on the host:

```bash
sysctl net.ipv4.ip_forward                           # must be 1
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-ip-forward.conf && sudo sysctl --system
```

If **Docker runs on the host**, it sets the firewall FORWARD policy to DROP, which blocks the VM. Allow the VM bridge (`virbr0`) to your uplink interface (find it with `ip route get 1.1.1.1`, for example `wlp3s0`):

```bash
sudo iptables -I DOCKER-USER -i virbr0 -o <uplink> -j ACCEPT
sudo iptables -I DOCKER-USER -i <uplink> -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

These rules are lost when Docker restarts. To make them persistent, add them as `ExecStartPost=-/usr/sbin/iptables ...` lines in a drop-in (`sudo systemctl edit docker`, under `[Service]`). Or simply stop Docker on the host, since Docker runs in the VM: `sudo systemctl disable --now docker.service docker.socket`. If your Docker uses nftables mode there may be no `DOCKER-USER` chain **(verify)**.

Other causes: `ufw` (`sudo ufw route allow in on virbr0 out on <uplink>`), a VPN client with a kill switch or "block local network" option, or a restarted libvirt network. **After restarting libvirt's network or the firewall, restart the VM**, otherwise it stays disconnected.

**`Permission denied` when the agent edits files in the shared folder.** The VM user's uid differs from the folder owner's uid (virtiofs does not remap owners). Compare `id -u` on the host and in the VM. The script now sets the VM uid to the host uid at creation. To fix an existing VM without recreating it, edit its disk offline (needs libguestfs tools, **verify package and options**):

```bash
sudo virsh -c qemu:///system shutdown claude-vm
sudo virsh -c qemu:///system snapshot-create-as claude-vm before-uid-fix
sudo virt-customize -a /var/lib/libvirt/images/claude-vm.qcow2 \
  --run-command 'usermod -u <HOST_UID> <user>' \
  --run-command 'groupmod -g <HOST_UID> <user>' \
  --run-command 'chown -R <HOST_UID>:<HOST_UID> /home/<user>' --selinux-relabel
```

Check first that the target uid is free in the VM (`virt-cat -a <image> /etc/passwd`).

**SSH `Permission denied (publickey)`.** The key in the cloud-init file did not match, or the user name differs. Cloud-init only applies on first boot: run `./setup-vm.sh destroy` and `./setup-vm.sh` again. Check `ssh -v claude-vm`.

**Shared folder not mounted in the VM.** Check `sudo dmesg | tail` in the VM and `cat /sys/fs/virtiofs/*/tag` (should list `dev`). Check on the host that `virtiofsd` is installed and that the VM XML has the filesystem (`sudo virsh -c qemu:///system dumpxml claude-vm | grep -A6 filesystem`). The fstab line uses `nofail`, so a missing share does not block booting.

**Provisioning failed (Claude Code is missing).** In the VM: `sudo less /var/log/cloud-init-output.log`. Usual causes: no internet (above), a changed vendor install URL (override `CLAUDE_CMD`).

**`virt-install` rejects a flag.** Your version may be too old for `--cloud-init` or `--osinfo`: upgrade it, or check `OSINFO` with `virt-install --osinfo list`.

## Limitations

- Linux hosts only (x86_64 assumed). One VM per `VM_NAME`.
- Packages, firewall behavior and libvirt service names differ between distros and releases. Expect to adjust things on first run on each.
- No built-in network allow-listing, no automatic updates of the VM, no host-package installer (by design: the script stays short enough to read in a few minutes).
