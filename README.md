* [Intoduction](#introduction)
* [Quick Start](#quick-start)
* [Use cases and deployment scenarios](#use-cases-and-deployment-scenarios)
* [Startup and Discovery](#startup-and-discovery)
* [Operation](#operation)
* [Requests, Tasks and Job Classes](#requests-tasks-and-job-classes)
* [Failure scenarios](#failure-scenarios)
* [Configuration](#configuration)


# Introduction

NkCLUSTER is a framework for creating clusters of Erlang nodes of any size, and distributing and managing jobs into them. It uses its own cluster management solution, based on [_NkDIST_](https://github.com/nekso/nkdist), [_riak_core_](https://github.com/basho/riak_core) and a [_custom distribution protocol_](src/nkcluster_protocol.erl). NkCLUSTER is one of the core pieces of the upcoming [_NetComposer_](http://www.slideshare.net/carlosjgf/net-composer-v2) platform, but can be used on its own.

Standard Erlang clusters are very convenient and easy to use, but they have some important limitations:
* Since each Erlang node must open a connection to any other node in the cluster, it is usually not practical to scale beyond about 50-100 nodes (_hidden nodes_ are a possible workaround).
* Limited transport options, only TCP is (easily) available. Not very firewall friendly.
* Sending large messages can affect the latency of other, small messages.
* Adding and removing nodes does not redistribute the load on the nodes.
* In practical terms, all nodes must usually belong to the same LAN.

NkCLUSTER allows the creation of clusters with a very large number of nodes. It uses a _hybrid_ approach. Any node in the cluster can have two different roles:

* _Control_ role: They receive, share and process requests from the network, and manage and send jobs to nodes with 'worker' role.
* _Worker_ role: They receive job requests from any node with _control_ role and execute them, and can also receive specialized network traffic to process. They can have also special jobs like being a network router or a disk server.

 All of the nodes of the cluster run the same Erlang application (_nkcluster_), but the first 'N' nodes in the cluster are _primary_ nodes (they have _control_ and _worker_ roles), and the rest of the nodes are _secondary_ nodes (they only have the _worker_ role). N must be power of two, typically 16, 32, 64 or 128. Primary nodes create a _riak_core_ cluster among them. The set of all primary nodes is called the primary cluster, a subset of the whole cluster.

Full nodes talk among them using standard Erlang distribution protocol. From the NkCLUSTER point of view, worker nodes talk only with their _node proxy_, placed at some control node, using TCP, TLS, SCTP, WS or WSS transports (they can of course talk with other worker nodes or whatever they want to using other means) . NkCLUSTER is designed to allow worker nodes to be deployed at WAN distances from control nodes (for example, at different cloud providers). They can be very _firewall-friendly_, for example using _websockets_ transports on port 80 or 443, and in some circumstances, without any opened incoming port. However, all control nodes should still belong to the same LAN.

NkCLUSTER uses the concepts of _requests_, _tasks_, _events_ and _job classes_. For each worker node, a _node proxy_ process is started at some specific control node, and can be used to send requests and tasks to its managed worker node. Requests are short-lived RPC calls. Tasks are long-living Erlang processes running at a worker node and managed from a control process at a control node. Events are pieces of information sent from a worker node to its node proxy. All of them must belong to a previously defined [_job_class_](src/nkcluster_job_class.erl).

Any node in the cluster can have a set of _labels_ or _metadata_ associated with it, with an _url-like format_. For example, `core;group=group1;master, meta2;labelA=1;labelB=2` would add two metadata items, `core` and `meta2`, each with some keys (`master`, `labelA`...) and, optionally, a value the key (`group1`, `2`...). This metadata can be used for any purpose, for example to group nodes or decide where to put an specific Task in the cluster.

NkCLUSTER includes some out-of-the-box tools like metadata management, hot remote loading (or updating) of Erlang code, launching OS commands, [Docker](https://www.docker.com) management, etc. NkCLUSTER allows _on the fly_ addition and removal of nodes (both control and workers) and it is designed to allow jobs to be developed so that service is not disrupted at any moment.

NkCLUSTER scales seamlessly, from a single machine to a 10-20 _control+worker_ nodes cluster, all the way to a _huge_ cluster, where, for example, 50-100 control nodes manage thousands or tens of thousands of worker nodes. In a future version, NkCLUSTER will allow dynamic creation of nodes in public clouds like Amazon or Azure or private ones like OpenStack.

NkCLUSTER requires Erlang R17+.


# Quick Start

```
git clone https://github.com/Nekso/nkcluster.git
make
```

Then, you can start five different consoles, and start five nodes, one at each: `make dev1`, `make dev2`, `make dev3`, `make dev4` and `make dev5`.

Nodes 1, 2 and 3 are control/worker nodes. Nodes 4 and 5 are worker nodes. The cluster should discover everything automatically, but you must deploy the cluster plan. At any node of 1, 2 or 3:

```erlang
> nkcluster_nodes:get_nodes().
[<<"dev1">>,<<"dev2">>,<<"dev3">>,<<"dev4">>,<<"dev5">>]

> nkcluster_nodes:get_node_info(<<"dev4">>).
{ok, #{id=><<"dev4">>, ...}}

> nkcluster:call(<<"dev3">>, erlang, node, [], 5000). 
{reply, 'dev3@127.0.0.1'}
```


# Use cases and deployment scenarios

NkCLUSTER is designed to solve an specific type of distributed work problem. It is probably useful for other scenarios, but it is specially well suited for the following case, where any _job class_ is a compound of up to three _layers_:

* A mandatory, lightweight _control_, _manager_, or _smart_ layer, written in Erlang (or any other BEAM language, like Elixir or LFE) that runs at all control nodes, so that any of them can receive a request to start or manage any task associated to this class. Optionally, a helper lightweight OS process or docker container could be started at its co-located worker node (written in any programming language).
* Optionally, a possibly heavyweight set of OS processes, docker containers or _pods_, running at specific worker nodes, and managed locally by an Erlang application sent from the control cluster _over the wire_, that talks with the controllers at the control nodes.
* Lastly, an optional, lightweight _state_ associated with each task, also written in Erlang, and running in the same control node than the _node proxy_ process for the worker node where the real job happens is located. Since node proxies are spread evenly among the cluster, your state processes will also be spread automatically.

NkCLUSTER includes full support for managing OS processes (using [NkLIB](https://github.com/Nekso/nklib)) and for managing Docker containers (using [NkDOCKER](https://github.com/Nekso/nkdocker)). The NkCLUSTER recommended approach is having, at the worker nodes, a local Erlang application monitoring processes and containers, and sending high-level, aggregated information to the control cluster, instead of sending raw stdout or similar low-level information. This way, even if the connection is temporarily lost, the worker node can continue working at some extend, while the connection to the control nodes is re-established.

This architecture is quite well suited for many real case scenarios, for example:

* SIP/WebRTC media processing framework, where:
	* [NkSIP](https://github.com/kalta/nksip) and WebRTC controllers run at every control node, accepting connections and managing SIP and WebRTC signaling.
	* each specific call or conference is an Erlang process that is evenly distributed at the control cluster.
	* a number of [Freeswitch](https://freeswitch.org/) instances are started at worker nodes as docker containers for the heavy media management (transcoding, recording, etc.)
* Software-defined storage network based on [Ceph](http://ceph.com), where:
	* the Ceph control daemons run in all of the control nodes.
	* the disk control daemons run at each worker node offering disks to the network (the middle layer would not be used in this case).
* Highly available [Kubernetes](http://kubernetes.io) cluster, where:
	* _etcd_ and _controlling_ processes run at the control nodes.
	* the _real work_ docker and controllers run at each specific worker node.
* Parallel or _streaming_ processing, where:
	* the control nodes receive streaming information to process, and decide which worker node must do the real processing. 	* For each task, an equivalent Erlang process is started at the control cluster.
	* The selected worker node receives the piece of information and process it, sending the response back.
* IoT platform, where:
	* the remote devices discover, talking with the control cluster, their associated worker node.
	* the device connects directly to their assigned worker node. Each worker node can handle a big number of devices. In case of failure, they find a new node and try to re-connect to it.


Depending on the configuration, several possible scenarios are supported:

* _Standard_. Each node listens on a defined port, using any supported transport. Then, you configure all nodes with the addresses of the control cluster (by hand or using NAPTR, SRV or multiple-DNS resolution):
	* The first node is started as a _control+worker_ node.
	* Zero or more nodes are started as _control+worker nodes_. They automatically discover other control nodes, connect to them and form a _riak_core_ cluster.
	* Zero or more nodes are started as _workers_ only, and, using configuration or DNS, they discover and connect to a random control node. The receiving control node decides the _final_ location for the control process (using riak_core distribution) and the correspoding _node proxy_ process starts there.
	* Each node proxy process starts a connection to its controlled worker node. In case of failure, or if a specific request asks for an exclusive connection (for example for sending big files), a new connection is started.
* _No-discovery_. If you don't offer a `cluster_addr` parameter, no discovery should occur. Control nodes must be joined manually, and connections to worker nodes must be explicitly started.
* _No-listening_. Worker nodes can work without a listening address (for example, behind a firewall not accepting any incoming connection). In this case, the discovery connections are reused from the worker nodes. However, in case of connection failure, control nodes must wait for the next discovery before reconnecting to the nodes.


# Startup and Discovery

The same Erlang application (`nkcluster`) is used at control (_control+worker_ nodes actually) nodes and worker-only nodes. When configuring a new node you must supply:

* A cluster name.
* A set of listening network points, using _[NkPACKET](https://github.com/nekso/nkpacket) url-like format_, for example `nkcluster://localhost;transport=tcp, nkcluster://localhost;transport=wss`
* A password.
* If the node is going to be a _control_ node (besides being a _worker_ node) or not.
* Metadata associated with the node.
* Optionally, one or several network addresses to discover control nodes.

If a set of _cluster discovery addresses_ are configured, the node will extract from them all transports, IP addresses and ports, it will randomize the list and try to connect to each one, until one accepts the connection. You should include all planned control nodes, DNS addresses returning several addresses, etc, for example:

```erlang
{cluster_addr, "nkcluster://my_domain, nkcluster://10.0.0.1:1234;transport=wss"}
```

It this example, the node will extract all IP addresses and ports from `my_domain` (using DNS), and will add `10.0.0.1:1234` using `wss` transport to the list. It will then randomize the list and start trying to connect to each one in turn.

The password for this specific node and tls options can be included in the url:
```erlang
{cluster_addr, "nkcluster://10.0.0.1:1234;transport=wss;password=pass1;tls_depth=2"}
```

NkPACKET supports the following DNS records for discovery:
* [_NAPTR_](https://en.wikipedia.org/wiki/NAPTR_record) records. If you don't supply port or transport, it will try to find a NAPTR record for the domain. For example, with this record:

	```
example.com NAPTR 10 100 "S" "NKS+D2W" "" _nks._ws.example.com.
example.com NAPTR 10 200 "S" "NKS+D2T" "" _nks._tcp.example.com. 
example.com NAPTR 10 300 "S" "NK+D2W" "" _nk._ws.example.com.
example.com NAPTR 10 400 "S" "NK+D2T" "" _nk._tcp.example.com.
example.com NAPTR 10 500 "S" "NK+D2S" "" _nk._sctp.example.com.
	```
NkCLUSTER will first try _WSS_ transport (resolving `_nks._ws.example.com` as a _SRV_ domain find IPs and ports), then _TLS_, then _WS_, then _TCP_ and finally _SCTP_ as a last resort.

* [_SRV_](https://en.wikipedia.org/wiki/SRV_record) records. After a _NAPTR_ respone, or if you supplied the desired transport, the corresponding _SRV_ record will be resolved. For example, if `tcp` was selected, with this record:

	```
_nk._tcp.example.com. 86400 IN SRV 0 5 1972 cluster.example.com.
	```
NkCLUSER will try to resolve `cluster.example.com`, taking all IPs from there and using port `1972`.

* [_Round-robin DNS_](https://en.wikipedia.org/wiki/Round-robin_DNS). Each time NkCLUSTER must resolve an IP address, if it returns multiple `A` records, it will randomize the list.

The receiving control node will accept the connection, and both parties will authenticate each other, sending a challenge (the node _UUID_, a random string auto-generated at boot) that must be _signed_ using the local password, with [PBKDF2](https://en.wikipedia.org/wiki/PBKDF2) protocol. If everything is ok, the control node will select the _right_ node to host the node proxy process and it will start it there. If the selected node is different, the node proxy will try to start a direct connection to the worker, if possible.

Using this node proxy process, you can send requests and start tasks at the worker node. Worker nodes will also send periodic information about its state (status, cpu, memory, etc.). If the connection fails, the control process will try to set it up again. Worker nodes will also try to connect again by themselves if no control node contacts them in a while. In some cases (like a network split) a single worker node could be _connected_ to several proxy processes at different nodes, but this should be a temporary situation, resolved once the cluster converges again.


# Operation

Based on _riak_core_, NkCLUSTER allows the addition and removal of nodes at any moment.

When a new control node is added, it automatically discovers and joins the riak_core cluster. While the cluster is reorganized, node proxy processes are relocated to be evenly distributed among the cluster again. When a node is removed, the opposite happens, also automatically.

Worker nodes can also be added and removed at any moment, and the changes are recognized automatically by the control nodes. Worker nodes can operate at the following states:

* _Launching_: The node is currently starting.
* _Connecting_: The cluster is currently trying to connect to the node.
* _Ready_: The node is ready to receive requests and tasks.
* _Standby_: The node is ready, but it is not currently accepting any new task.
* _Stopping_: The node is scheduled to stop as soon as no remaining tasks are running. It does not accept any new task. All tasks are notified to stop as soon as possible. Once all tasks have stopped, the status changes to _Stopped_ automatically.
* _Stopped_: The node is alive but stopped, not accepting any new task. 
* _Not Connected_: The cluster is not currently able to connect to the node.

Requests are allowed in _ready_, _standby_, _stopping_ and _stopped_ states.


# Requests, Tasks and Job Classes

Before sending any request or task to a worker node, you must define a _job_class_ module, implementing the [`nkcluster_job_class`](src/nkcluster_job_class.erl) behaviour. This callback module must be available a both sides (control and worker). You must implement the following callbacks:

Name|Side|Description
---|---|---
request/2|Worker|Called at the worker node when a new request must be processed. Must send an immediate reply.
task/2|Worker|Called at the worker node when a new task is asked to start. Must start a new process and return its `pid()` and, optionally, an immediate response. The task can send _events_ at any moment.
command/3|Worker|Called at the worker when a new command is sent to an existing task. Must return an immediate reply.
status/2|Worker|Called at the worker when the node status changes. If the status changes to `stopping`, the task should stop as soon as possible.
event/2|Control|Called at the control node when a task at the worker side sends an event back.

You can send your own Erlang module (or modules) to the remote side, over the wire, using `nkcluster:load_module/3` or `nkcluster:load_modules/3`. 

Once defined your _job_class_ module, you can send requests, start tasks and send messages to tasks. Tasks can send events back to the job class.

You can send requests calling `nkcluster:request/3,4`. The callback `request/2` will be called at the remote (worker) side, and your call will block until a response is sent back. You can define a _timeout_, and also ask NkCLUSTER to start a new, exclusive connection to the worker if possible. If the connection or the node fails, an error will be returned. If you are not asking for a new, exclusive connection, you request processing time must be very short (< 100 msecs). Otherwise, the periodic ping will be delayed and the connection may be dropped.

For long-running jobs, you must start a new task, calling `nkcluster:task/3,4`. The callback `task/2` will be called at the remote side, and it must start a new Erlang process and return its `pid()` and, optionally, a reply. A _job_id_ is returned to the caller, along with the reply if sent. You can send mesages to any started task calling `nkcluster_jobs:command/4,5`.

The started task can send _events_ back to the control node at any moment, calling `nkcluster_jobs:send_event/2`. The event will arrive at the control node, and the callback `event/2` will be called for the corresponding job class. NkCLUSTER will also send some automatic events:

Event|Description
---|---
{nkcluster, {task_started, TaskId}}|The task has successfully started.
{nkcluster, {task_stopped, TaskId, Reason}}|The task has stopped (meaning the Erlang process has stopped).
{nkcluster, {node_status, nkcluster:node_status()}}|The node status have changed. If it changes to `not_connected` some event may have been lost.

 
## Built-in requests

NkCLUSTER offers some standard utility requests out of the box, available in the [`nkcluster`](src/nkcluster.erl) module:

Name|Desc
---|---
get_info/0|Gets current information about the node, including its status
set_status/1|Changes the status of the node
get_tasks/1|Gets all tasks running at a worker node
get_tasks/2|Gets all tasks running at a worker node and belonging to a job class
get_meta/1|Gets the current metadata of a remote node
update_meta/2|Updates the metadata at a remote node
get_data/2|Stored a piece of data at the remote registry
put_data/3|Updates a piece of data at the remote registry
call/5|Calls an Erlang function at a remote node
spawn_call/5|Calls an Erlang function at a remote node, not blocking the channel
send_file/3|Sends a file to a remote node. For files > 4KB, it switches to send_bigfile/3.
send_bigfile/3|Sends a file to a remote node, starting a new connection (if possible), in 1MByte chunks
load_module/2|Sends a currently loaded Erlang module and loads it a the remote node
load_modules/2|Sends a currently loaded Erlang set of modules and loads them to the remote node


# Failure scenarios

## Connection failure

When the main connection of a node proxy to its managed worker node fails, the following things happen:

* An `{error, connection_failed}` error is returned to all pending requests sent over this connection and still waiting for a response. Since the connection has failed, the remote connection (and the request itself, since it is usually running in the same process) have also probably failed (you can't however assume this for sure). 
* An `{nkcluster, {node_status, not_connected}}` event is sent to all classes that the control node has _seen_ (all classes that have received at last one event). Job classes must then assume that some events may have been lost, and must try to recover its state once the connection is alive again.
* The control node will try to connect immediately to the remote node (only if it published one or several listening points). If it fails, it will try again periodically. Meanwhile, all new requests will fail. 
* If the remote worker didn't publish any listening address, the control process exists. The remote node should try to discover nodes again periodically, and a new control process will then be started.

Requests can start a secondary, exclusive connection. In this case, the failure of the main connection does not affect them (but affect their events). If this exclusive connection is the one who fails, the request will fail in the same manner described above.


## Node failure

If the node proxy process fails (because of the failure of the whole control node or a bug), all pending requests will also fail (since they are using `gen_server:call/3` under the hood). The worker node will detect this and try to announce itself again. The control cluster will then start a new node proxy process at the same (if again alive) or other node.

If the worker node process fails (because of the failure of the whole worker node or a bug), the control process will enter into _not_connected_ state, notifying all detected job classes as described before. If the worker node no longer exists, you must call `nkcluster_nodes:stop(NodeId)` to remove it.


# Configuration

NkCLUSTER uses standard Erlang application environment variables. The same Erlang application is used for agents and controllers. 

Option|Type|Default|Desc
---|---|---|---
cluster_name|`term()`|`"nkcluster"`|Nodes will only connect to other nodes in the same cluster
cluster_addr|`nklib:user_uri()`|`""`|List of control nodes to connect to (see above)
password|`string()|binary()`|`"nkcluster"`|Password to use when connecting to or from control nodes
meta|`string()|binary()`|`""`|Metadata for this node (i.e. `"class;data=1, location;dc=here"`)
is_control|`boolean()`|`true`|If this node has the `control` role
listen|`nklib:user_uri()`|`"nkcluster://all;transport=tls`|List of addresses, ports and transports to listen on (see above)
tls_certfile|`string()`|-|Custom certificate file
tls_keyfile|`string()`|-|Custom key file
tls_cacertfile|`string()`|-|Custom CA certificate file
tls_password|`string()`|-|Password fort the certificate
tls_verify|`boolean()`|false|If we must check certificate
tls_depth|`integer()`|0|TLS check depth
