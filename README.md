To build the artifact, run
```bash
tt pack tgz --with-binaries
```

To set up etcd config storage, run
```bash
etcd
```

```
2024-04-02 11:18:59.429663 I | embed: listening for peers on http://localhost:2380
2024-04-02 11:18:59.429692 I | embed: listening for client requests on localhost:2379
```

```bash
ETCDCTL_API=3 etcdctl user add root:topsecret
ETCDCTL_API=3 etcdctl role add myapp_config_manager
ETCDCTL_API=3 etcdctl role grant-permission myapp_config_manager --prefix=true readwrite /myapp/
ETCDCTL_API=3 etcdctl user add sampleuser:123456
ETCDCTL_API=3 etcdctl user grant-role sampleuser myapp_config_manager
ETCDCTL_API=3 etcdctl auth enable
```

To publish a configuration
```bash
tt cluster publish "http://sampleuser:123456@localhost:2379/myapp" source.yaml
```

To start an application
```bash
tt start
```
