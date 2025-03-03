# cni testbed

This tool can create the testbed for developing CNI（velocis, celeris）using [kind](https://kind.sigs.k8s.io/) and [containerlab](https://containerlab.dev/)

## Usage

The following command creates the CNI testbed.

```bash
make testbed
```

To delete testbed, you can use the following commands.  

```bash
make cleanup
```

The architecture of CNI testbed is as follows.  

![cni_testbed](./docs/architecture/cni_testbed.drawio.svg)
