# darg-home-ops

## Setup

```sh
task talos:get-config
task talos:apply-node IP=192.168.1.203 EXTRA_ARGS=--insecure
task bootstrap:default ROOK_DISK=none
```
