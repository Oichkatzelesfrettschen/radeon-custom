# Debian/XanMod Radeon DKMS Adapter

This directory is the Debian-family packaging frontend for the canonical
`src/re/radeon/` DKMS patchset.

Current transition status:

| File | Meaning |
|---|---|
| `dkms.conf` | Existing `radeon-palm-gate` DKMS config copied from the x130e tested staging tree. |
| `prep-source.sh` | Source extraction and Palm patch staging logic. |
| `install.sh` / `uninstall.sh` | Existing x130e install helpers. |

The package still uses the `radeon-palm-gate` identity until the
RS480/CachyOS and Palm/x130e patch families are combined into one
generated source tree.  New x130e work should land in
`../../patches/palm/` first and then be consumed by this adapter.

Install on x130e:

```bash
sudo install -d /usr/src/radeon-palm-gate-1.0
sudo cp -a . /usr/src/radeon-palm-gate-1.0/
cd /usr/src/radeon-palm-gate-1.0
sudo ./install.sh
dkms status
```

Upgrade-survival check:

```bash
dkms status radeon-palm-gate/1.0
modinfo -k "$(uname -r)" radeon | grep palm_pci_reset_unsafe
```
