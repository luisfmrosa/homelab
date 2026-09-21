# Coolify instructions

After installing an application in Coolify, you need to perform some manual steps to make it work on your laptop.

## Step 1: update Coolify's service domain

Go to Settings / Domain and these 2 entries:

- http://<my-coolify-service>.apps.homelab/ - domain for local access
- http://<my-coolify-service>.vpn.homelab/ - domain for VPN-tailscale access

Do not redirect http to https!


## Step 2: add these entries to Windows hosts file

We do not have local DNS, so we need these domains to be added to the local hosts file so your browser understands it:

192.168.1.200 <my-coolify-service>.apps.homelab
100.64.0.3    <my-coolify-service>.vpn.homelab

## Step 3: accessing the Coolify service

All apps are available by their specific domain through the same port, 8384.

On your browser, access: http://<my-coolify-service>.apps.homelab:8384

It should redirect to your Coolify service.