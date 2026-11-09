# Claude Code Workflow - Manual Installation on Fedora

Run Claude Code, Docker and builds inside a KVM VM. Share one folder from the host so you can edit with VS Code on the host *and* inside the VM against the same files.

Names used below (change to yours): VM `claude-vm`, user `user`, key `~/.ssh/claude_vm_ed25519`, Wi-Fi interface `wlp1s0`, shared folder `~/working-directory`.

## 1. Host: install libvirt

```bash
sudo dnf group install virtualization
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $USER
set -Ux LIBVIRT_DEFAULT_URI qemu:///system
```
Log out and back in, then check KVM:
```bash
virt-host-validate qemu
```

## 2. Host: fix VM networking

If Docker runs on the host, it sets a firewall forward policy that drops VM traffic. Symptom: the VM can ping the host (`192.168.122.1`) but not `1.1.1.1`. Also make sure IP forwarding is on.
```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-ip-forward.conf
sudo sysctl --system
```
**Option A, stop Docker on the host** (simplest; Docker will run in the VM):
```bash
sudo systemctl disable --now docker.service docker.socket
```
**Option B, keep Docker on the host** and allow the VM through it:
```bash
sudo systemctl edit docker
```
Paste, then save:
```ini
[Service]
ExecStartPost=/usr/sbin/iptables -I DOCKER-USER -i virbr0 -o wlp1s0 -j ACCEPT
ExecStartPost=/usr/sbin/iptables -I DOCKER-USER -i wlp1s0 -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```
```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
```

## 3. Host: create the VM

SSH key and cloud-init file (in a folder outside `~/working-directory`, e.g. `~/claude-vm`):
```bash
mkdir -p ~/claude-vm
cd ~/claude-vm
ssh-keygen -t ed25519 -f ~/.ssh/claude_vm_ed25519 -C claude-vm
printf '#cloud-config\nhostname: claude-vm\nusers:\n  - name: user\n    groups: wheel\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    shell: /bin/bash\n    ssh_authorized_keys:\n      - %s\n' (cat ~/.ssh/claude_vm_ed25519.pub) > user-data.yaml
cat user-data.yaml
```
Then download the **Fedora Cloud Base (Generic) qcow2** image and create the VM with the shared folder:
```fish
sudo cp ~/Downloads/Fedora-Cloud-Base-Generic-*.qcow2 /var/lib/libvirt/images/claude-vm.qcow2
sudo qemu-img resize /var/lib/libvirt/images/claude-vm.qcow2 200G

sudo virt-install --name claude-vm --memory 16384 --vcpus 8 \
  --osinfo fedora-unknown --import \
  --disk /var/lib/libvirt/images/claude-vm.qcow2 \
  --cloud-init user-data=$PWD/user-data.yaml \
  --memorybacking source.type=memfd,access.mode=shared \
  --filesystem source=$HOME/working-directory,target=dev,driver.type=virtiofs \
  --network network=default --noautoconsole
```
Sizes assume 32 GB RAM and a 1 TB disk. The disk is thin-provisioned. Adjust `--vcpus` to about half of `nproc`.

Wait about 30 seconds and get the IP:
```fish
virsh domifaddr claude-vm
```
Add to `~/.ssh/config`:
```
Host claude-vm
  HostName <vm-ip>
  User user
  IdentityFile ~/.ssh/claude_vm_ed25519
  IdentitiesOnly yes
  ForwardAgent no
```

## 4. VM: provision

```fish
ssh claude-vm
```
Inside the VM:
```bash
sudo dnf upgrade -y
sudo dnf install -y git
id                                   # note your uid; it should match the host's (usually 1000)

mkdir -p ~/working-directory
echo "dev /home/user/working-directory virtiofs defaults 0 0" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount -a
ls ~/working-directory                             # your host files should appear
```
Then install:
- **Docker Engine** (docs.docker.com/engine/install/fedora), then `sudo usermod -aG docker $USER` and log out and in.
- **Claude Code** (code.claude.com/docs), then run `claude` and sign in. If the browser login fails, use the copy-URL / paste-code option.

Take a clean snapshot:
```fish
virsh shutdown claude-vm
virsh snapshot-create-as claude-vm clean-base
virsh start claude-vm
```

## 5. VS Code on host and in the VM

Two windows, same files:

- **Host window:** VS Code on `~/working-directory/<project>`.
- **VM window:** install **Remote - SSH**. Press `Ctrl+Shift+P`, run **Remote-SSH: Connect to Host...**, pick `claude-vm`, then **File → Open Folder** `/home/user/working-directory/<project>`. Install the **Claude Code** extension on the SSH side ("Install in SSH: claude-vm").

The bottom-left corner shows `SSH: claude-vm` in the VM window. The first connection downloads the editor server to the VM, so the VM needs internet access.

Terminal shortcut:
```fish
code --remote ssh-remote+claude-vm /home/user/working-directory/<project>
```

## 6. Daily use

```fish
virsh start claude-vm                # if not running
```
Open both windows. Run Claude, Docker, builds and tests in the **VM window** only. Use the **host window** for reading and reviewing changes.

Before a risky or unattended run:
```fish
virsh shutdown claude-vm
virsh snapshot-create-as claude-vm before-task
virsh start claude-vm
```

To roll back: `virsh shutdown claude-vm`, then `virsh snapshot-revert claude-vm before-task`. Commit anything you care about first, because the shared folder is on the host, so work saved there survives a revert but the VM's own state does not.

## 7. Security notes for the shared folder

- **Claude can write to the shared folder, and so can anything it runs.** Files like `.git/hooks`, `package.json` scripts, `node_modules/.bin`, `.vscode/tasks.json` and `.envrc` can later run on the host if you execute them there. Run git commands, builds and tests inside the VM, and review diffs before running anything from the folder on the host.
- **Share as little as possible.** `~/working-directory` exposes every project in it. If you can, share just the current project.
- **Keep secrets out of the shared folder and out of the VM:** no `~/.ssh`, no cloud credentials. Use a fork-scoped token if Claude needs to push.
- **No SSH agent forwarding** (`ForwardAgent no`).
- **Network:** the VM can reach the whole internet by default. Restrict egress later if needed.
- **Run Claude as a non-root user** if you use `--dangerously-skip-permissions`.
