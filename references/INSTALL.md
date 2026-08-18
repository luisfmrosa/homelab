# Homelab setup

This document describes the manual steps taken in the initial setup of the server.


## Steps

### 1. Preparing the installation disk

On the laptop:

1. Download and install Balena Etcher: https://etcher.balena.io/
1. Download Debian image: https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.6.0-amd64-netinst.iso
1. Conect the SSD to be used to install Debian via USB
1. Flash Debian image in the SSD via Balena Etcher.

### 2. Install Debian

On the homelab:

1. Plug the SSD with the Debian image on the USB
1. Reboot and type F2 to enter the BIOS
1. Set boot priority to the SSD with Debian (USB)
1. Hit key F10 to save changes and restart. Debian installation should start
1. On storage setup, delete all existing partitions from local disk
1. Enter into manual partition mode
1. Set a partition for EFI (vfat, 512 MB). Name it "EFI"
1. Set another partition for the remaining space, type BTRFS, mount point: /, name: SYSTEM, label: SYSTEM, mounting options: check "noatime"
1. On the software selection, keep only minimal options:

```
[ ] Debian desktop environment (UNCHECK)
[ ] ... any graphical interface ... (UNCHECK)
...
[*] SSH server (CHECK)
[*] Standard system utilities (CHECK)
```
### 3. Remaining configurations on the server

#### Step 1: Set up TRIM for the SSD:

``` bash
sudo systemctl enable --now fstrim.timer
```

#### Step 2: configure Bluetooth keyboard

1. With a wired keyboard connected to the mini PC, install needed packages:

``` bash
sudo apt update
sudo apt install bluez bluetooth
sudo systemctl enable --now Bluetooth
```

2. Now time to scan devices, find the keyboard and pair it:
``` bash
sudo bluetoothctl
```

3. In the specific shell (prompt ```\[bluetooth]#```):

```
power on
agent KeyboardOnly
default-agent
```

**Note:** We use the agent ```KeyboardOnly``` because keyboards ask for a numeric code in the screen to confirm the pairing (you need to type it the shown code on the Bluetooth keyboard to pair it safely).

4. Put the keyboard in pairing mode

5. Now start scanning:

```
scan on
```

Devices found will start to pop up in the screen. Search for the keyboard and note the MAC address:

```
[NEW] Device XX:XX:XX:XX:XX:XX Nome_Do_Teclado
```

6. Pair the keyboard:

```
pair XX:XX:XX:XX:XX:XX
```

7. If it finds the device, it will show a 6-digit number. Type it directly on the Bluetooth keyboard and then hit ENTER.
8. If the pairing is successful, stop scanning:
```
scan off
```
9. Trust and connect

To ensure the keyboard connects automatically when it is turned on, we need to trust it:

```
trust XX:XX:XX:XX:XX:XX
connect XX:XX:XX:XX:XX:XX
```

If all goes well, you should see ```Connection successful.```

10. Quit the tool:

```
quit
```

### Static IP and DNS configurations

1. get homelab MAC address first. On the homelab shell, type:

```bash
ip a
```

Search for ```wlo1```. The MAC address will be after ```link/ether```.

2. Open the local router's page
3. Add a static IP for the homelab's MAC address. Ex.: ```<homelab-ip> XX:XX:XX:XX:XX:XX```
4. Reboot the homelab and check the IP address again with ```ip a```. The IP should be ```<homelab-ip>``` now
5. On the router's page, add an entry on the DNS: ```<homelab-ip> homelab```
6. On Windows laptop, edit ```C:\Windows\System32\drivers\etc\hosts``` and add an entry for the server:
```
<homelab-ip> homelab
```
Now homelab should redirect to our homelab server!

### Setup SSH trusted connections between homelab and laptop

On the laptop:

#### Step 1: On a Powershell terminal, run the command to create the keys:

``` Powershell
ssh-keygen -t ed25519 -C "laptop-windows"
```

Output:

``` Powershell
PS > ssh-keygen -t ed25519 -C "laptop-windows"
Generating public/private ed25519 key pair.
Enter file in which to save the key (C:\\Users\\user/.ssh/id\_ed25519):
Enter passphrase (empty for no passphrase):
Enter same passphrase again:
Your identification has been saved in C:\\Users\\user/.ssh/id\_ed25519
Your public key has been saved in C:\\Users\\user/.ssh/id\_ed25519.pub
The key fingerprint is:
SHA256:gcLw2BwAzQHJRG75nk0VRnVQKO8L9pftStuEdqjsuI4 laptop-windows
The key's randomart image is:
+--\[ED25519 256]--+
|\*O+o. .+.o+o     |
|o.+B ..o...      |
| +. \* ..+        |
|. .  ..  o       |
|   . .  S        |
|  . +  o .  o    |
|   o .. o .=oo   |
|      . oo+o=.   |
|     E.+o+.ooo   |
+----\[SHA256]-----+
```

#### Step 2: copy the SSH public key to the homelab:

Run the following command on a Powershell terminal:

``` Powershell
type "$env:USERPROFILE\\.ssh\\id\_ed25519.pub" | ssh <your-user>@homelab "mkdir -p \~/.ssh \&\& cat >> \~/.ssh/authorized\_keys \&\& chmod 700 \~/.ssh \&\& chmod 600 \~/.ssh/authorized\_keys"
```

Type your homelab user password.

If successful, now you can SSH the homelab from the laptop without being asked for password.

``` Powershell
PS C:\\Users\\falec> ssh luis@homelab
Linux homelab 6.12.95+deb13-amd64 #1 SMP PREEMPT\_DYNAMIC Debian 6.12.95-1 (2026-07-04) x86\_64

The programs included with the Debian GNU/Linux system are free software;
the exact distribution terms for each program are described in the
individual files in /usr/share/doc/\*/copyright.

Debian GNU/Linux comes with ABSOLUTELY NO WARRANTY, to the extent
permitted by applicable law.
luis@homelab:\~$
```

From now on, all changes in Server's configuration can be done through Ansible scripts, directly from the laptop.

### 4. Install Ansible on Windows laptop

#### Step 1: Install Ubuntu on WSL:

``` Powershell
wsl --install
```

This will install a Ubuntu image by default or enter on Ubuntu if already installed.

```
PS C:\Users\falec> wsl --install
Downloading: Ubuntu
Installing: Ubuntu
Distribution successfully installed. It can be launched via 'wsl.exe -d Ubuntu'
Launching Ubuntu...
Provisioning the new WSL instance Ubuntu
This might take a while...
Create a default Unix user account: falec
New password:
Retype new password:
passwd: password updated successfully
usermod: no changes
Help improve Ubuntu!

Help us improve Ubuntu features and compatibility by sharing system reports with Canonical.
Reports are sent anonymously and do not contain any personal data.
For legal details, please visit: https://ubuntu.com/legal/systems-information-notice

We will save your answer to Windows and will only ask you once.

Would you like to opt-in to platform metrics collection (Y/n)? To see an example of the data collected, enter 'e'.
[Y/n/e]: n
user@laptop:/mnt/c/Users/falec$
```

#### Step 2: Install Ansible inside Ubuntu (WSL):

```bash
# Update package list in Ubuntu
sudo apt update && sudo apt upgrade -y

# Install Pip and dependencies
sudo apt install python3-pip python3-venv -y

# Install pipx to avoid conflicts with system Python
sudo apt update && sudo apt install pipx -y
sudo pipx completions

# Ensure installed packages are available on the path
pipx ensurepath
source ~/.bashrc

# Install Ansible with Pip (most recommended and updated)
pipx install ansible --include-deps
```

To test if all is OK:

```bash
ansible --version
```

#### Step 3: copy SSH keys to WSL

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp /mnt/c/Users/falec/.ssh/id_* ~/.ssh/
chmod 600 ~/.ssh/id_*
```

Test a SSH connection to the homelab: it should be done without asking for password.

``` bash
ssh luis@homelab
```

#### Step 4: install the incus client in WSL and trust the homelab remote

Some playbooks (e.g. `src/ansible/playbooks/headscale.yml`) connect to Incus instances directly via `incus exec`, using Ansible's `community.general.incus` connection plugin, instead of SSH. Since `ansible-playbook` itself runs from WSL/Ubuntu, WSL needs its own working `incus` CLI trusted against the `homelab` remote — separate from the Windows-side `incus` CLI installed in step 5 below, which lives in a different config location and isn't visible from WSL.

```bash
# Install the incus client in WSL/Ubuntu
sudo apt update
sudo apt install -y incus-client
```

Test if all is ok:

```bash
incus --version
```

Generate a trust token on the homelab (reuses the same one-time-token mechanism as the Windows-side remote in step 5 — see `references/ANSIBLE.md` for how `incus.yml` generates one automatically on first run, or generate a fresh one manually):

```bash
ssh luis@homelab "incus config trust add"
```

Copy the printed token, then add and switch to the remote from WSL:

```bash
incus remote add homelab https://homelab:8443 --token <paste-token-here>
incus remote switch homelab
```

Test it can reach the instance list:

```bash
incus list
```

#### Step 5: quick Ansible test

Create the file ```hosts```:

```
[myhosts]
homelab ansible_user=luis
```

Test if ansible finds it:

```bash
user@laptop:/mnt/c/Users/falec/Documents/Claude/Projects/homelab/scripts/ansible$ ansible myhosts -i hosts -m ping
[WARNING]: Host 'homelab' is using the discovered Python interpreter at '/usr/bin/python3.13', but future installation of another Python interpreter could cause a different interpreter to be discovered. See https://docs.ansible.com/ansible-core/2.21/reference_appendices/interpreter_discovery.html for more information.
homelab | SUCCESS => {
    "ansible_facts": {
        "discovered_interpreter_python": "/usr/bin/python3.13"
    },
    "changed": false,
    "ping": "pong"
}
```

If you had the output above, all is good!

### 5. Install incus client and incus-compose on Windows

#### Step 1. Install ```incus```

``` Powershell
winget install LinuxContainers.Incus
```

Test if all is ok:

``` Powershell
incus --version
```

#### Step 2. Install  ```incus-compose```

``` Powershell
# 1. Search the folder where Winget installed incus.exe
$IncusPath = Split-Path (Get-Command incus.exe).Source

# 2. Download incus-compose archive using curl
curl.exe -L "https://github.com/lxc/incus-compose/releases/download/v1.0.0/incus-compose_1.0.0_windows_amd64.tar.gz" -o "$env:USERPROFILE\Downloads\incus-compose.tar.gz"

# 3. Extract executable directly into the incus folder
tar.exe -xf "$env:USERPROFILE\Downloads\incus-compose.tar.gz" -C "$IncusPath" incus-compose.exe

# 4. Clean up the archive from Downloads
Remove-Item "$env:USERPROFILE\Downloads\incus-compose.tar.gz"
```

Test if all is ok:

``` Powershell
incus-compose version
```

#### Step 3. Add homelab as a remote and set it as default

The `src/ansible/playbooks/incus.yml` playbook generates a one-time trust token the first time it runs on a host with no trusted clients yet, and prints it in the Ansible output (see `references/ANSIBLE.md`). Copy that token, then on the Windows laptop add the remote using it and switch to it:

``` Powershell
incus remote add homelab https://<homelab-ip>:8443 --token <paste-token-here>
incus remote switch homelab
```

If you need a new token later (e.g. the first one expired or you already have a trusted client and need to trust another), generate one manually on the homelab instead:

``` bash
incus config trust add
```

### 6. Install and configure OpenTofu on Windows

OpenTofu talks directly to the Incus daemon's HTTPS API using the same client trust (certificate) already set up for the `incus`/`incus-compose` CLIs in step 5 — nothing needs to be installed on the homelab itself, and no SSH is involved.

#### Step 1. Install ```tofu```

``` Powershell
winget install OpenTofu.Tofu
```

Test if all is ok:

``` Powershell
tofu --version
```

#### Step 2. Verify it can reach the homelab remote

The `lxc/incus` OpenTofu provider (declared in `src/opentofu/`) picks up the trusted `homelab` remote from the same Incus client config used by `incus`/`incus-compose` (`%USERPROFILE%\.config\incus\`), so as long as step 5's remote is already added and trusted, no separate provider-side login is needed.

``` Powershell
cd src/opentofu
tofu init
tofu plan
```

### Force a static IPv6 on the Router:

1. add a static IPv6 on the router for the homelab.

2. modify `/etc/dhcpcd.conf` and add the following block at the end:
```
# Request a full stateful DHCPv6 lease for wlo1
interface wlo1
ia_na 1
```

3. restart the network interface: `sudo systemctl restart networking`

4. confirm the additional, static IPv6 appears: `ip -6 addr show wlo1`

### headscale

Manual steps needed on top of `src/opentofu/headscale.tf` and `src/ansible/playbooks/headscale.yml` (see `references/OPENTOFU.md` and `references/ANSIBLE.md`) — things a router UI or a third-party DNS provider that Ansible/OpenTofu can't reach.

The container sits on the default NAT'd `incusbr0` bridge (not directly on the router's network) — a `macvlan` NIC on the homelab's physical `wlo1` was tried first, so the container could get its own IPv6 directly from the router, but **macvlan doesn't work reliably over WiFi**: the container had a global IPv6 address and a default route, but zero actual reachability (ping and DNS both hung indefinitely), because WiFi access points generally only accept traffic for the one MAC they associated with — a second virtual MAC riding the same radio gets silently dropped. `headscale.tf` instead forwards the needed ports from the **homelab host's own** address to the container via Incus `proxy` devices, so the firewall rule and DNS both point at the homelab host itself, not the container.

#### Step 1: find the homelab host's IPv6

```bash
ssh luis@homelab "ip -6 addr show wlo1"
```

Use the `global` address shown (not the `fe80::...` link-local one) — the same one already used for the homelab host's own DNS entry (see "Static IP and DNS configurations" above).

#### Step 2: add a router firewall rule allowing external access to headscale's ports

Forward/allow the following from the internet to the **homelab host's** IPv6 (not the container's — Incus `proxy` devices on `headscale.tf` forward from the host into the container):

```
443/tcp  -> homelab host IPv6  (Caddy: HTTPS + headscale API)
80/tcp   -> homelab host IPv6  (Caddy: ACME HTTP-01 challenge)
3478/udp -> homelab host IPv6  (embedded DERP STUN)
```

#### Step 3: create/update the DuckDNS domain

1. On https://www.duckdns.org, sign in and point the domain (already registered; the real name lives in the gitignored `01-local.yml` as `headscale_domain`) at the homelab host's IPv6 from Step 1 (DuckDNS supports an AAAA-only update — see their site for the exact update URL/token).
   * **Make sure no stale A (IPv4) record is left on the domain.** DuckDNS keeps the IPv4 and IPv6 records independent, so updating only the AAAA record leaves any old A record in place. Clients that try IPv4 first (many Tailscale/Tailscale-compatible clients, including the Android and Windows apps) will then hang indefinitely trying to connect to a dead IPv4 address before ever falling back to the working IPv6 one — this caused node enrollment to silently stall on both platforms even though a plain HTTPS request (e.g. `/health`) succeeded. Clear the A record on DuckDNS's site (leave the IPv4 field blank) if one exists.
2. If the domain name ever changes, update it in these files:
   * `src/ansible/group_vars/all/00-defaults.yml` — `headscale_domain`
   * Re-run `ansible-playbook -i src/ansible/hosts src/ansible/playbooks/headscale.yml` to regenerate the Caddyfile and headscale `config.yaml` (`server_url`, `dns.base_domain`) from the new value and re-issue the Let's Encrypt certificate.

#### Step 4: create headscale users

User creation is automated by `headscale.yml` (see `references/ANSIBLE.md`). Add the usernames you want to `headscale_users` in the gitignored `src/ansible/group_vars/all/01-local.yml` (created for `naspool_disks`, see Step 2 in the main setup above), e.g.:

```yaml
headscale_users:
  - luis
```

Then re-run:

```bash
ansible-playbook -i src/ansible/hosts src/ansible/playbooks/headscale.yml
```

Node registration itself is **not** automated — a device needs an interactive nodekey or pre-auth key at enrollment time. To add a device (e.g. a smartphone) manually:

1. Install the Tailscale app on the device and set its coordination/login server to `https://<mydomain>.duckdns.org` (exact field name varies by platform — look for "custom control server" or "alternate coordination server").
2. Start the login flow on the device; it will produce a pending registration.
3. Approve it from the homelab, e.g. via WSL:
   ```bash
   incus exec headscale --remote homelab -- headscale nodes register --user <username> --key <nodekey-shown-by-the-app>
   ```

#### Step 5: headplane (web UI)

Headplane is reachable at `https://<mydomain>.duckdns.org/admin/` (note the trailing slash — without it Caddy's `handle /admin/*` doesn't match and the request goes to headscale instead) once `src/ansible/playbooks/headplane.yml` has run (see `references/ANSIBLE.md`) — no additional manual/router steps needed, it reuses the same ports and Let's Encrypt certificate as headscale itself. Log in using the API key generated for it (`incus exec headscale -- cat /etc/headplane/api_key`).

**END**