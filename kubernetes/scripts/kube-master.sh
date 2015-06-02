#!/bin/bash
# Kubernetes cluster master

# Define master and nodes
KUBE_MASTER="10.68.246.12"

# Set proxy if needed
PROXY=""

# Source and Git repo 
ETCD_DL="https://github.com/coreos/etcd/releases/download/v2.0.11/etcd-v2.0.11-linux-amd64.tar.gz"
GO_DL="https://storage.googleapis.com/golang/go1.4.2.linux-amd64.tar.gz"
FLANNEL_DL="https://github.com/coreos/flannel/releases/download/v0.4.1/flannel-0.4.1-linux-amd64.tar.gz"
KUBERNETES_GIT="https://github.com/GoogleCloudPlatform/kubernetes.git"

# Suggest not to change the following 
GIT_HOME="/root"
FLANNEL_NETWORK="172.16.0.0/16"
KUBE_NETWORK="172.16.0.0/24"
KUBE_ROOT="${GIT_HOME}/kubernetes"
API_HOST=${KUBE_MASTER}
API_PORT="8080"
KUBELET_PORT="10250"
LOG_LEVEL="3"
CHAOS_CHANCE="0.0"
GO_OUT="${KUBE_ROOT}/_output/local/bin/linux/amd64"
LOG_DIR="/var/log/kubernetes"; mkdir -p ${LOG_DIR} 

if [ ! -f ${GIT_HOME}/.kubeinstalled ]; then
        echo "Installing software..."  
        yum -y install git curl gcc docker
	systemctl stop docker.service
	systemctl disable docker.service
        
	# Remove the default docker0 bridge
	ip link set dev docker0 down
	brctl delbr docker0

	# User zzdocker0 as the bridge
	cat > /usr/lib/systemd/system/docker.service << EOF
	[Unit]
	Description=Docker Application Container Engine
	Documentation=http://docs.docker.com
	After=network.target

	[Service]
	Type=notify
	Environment="BRIDGE=zzdocker0"
	EnvironmentFile=-/etc/sysconfig/docker
	EnvironmentFile=-/etc/sysconfig/docker-storage
	EnvironmentFile=-/etc/sysconfig/docker-network
	EnvironmentFile=-/run/flannel/subnet.env
	ExecStart=/usr/bin/docker -d \$OPTIONS \
			\$DOCKER_STORAGE_OPTIONS \
            		\$DOCKER_NETWORK_OPTIONS \
			\$ADD_REGISTRY \
			\$BLOCK_REGISTRY \
			\$INSECURE_REGISTRY \
			--bridge=\${BRIDGE} \
			--mtu=\${FLANNEL_MTU}
	LimitNOFILE=1048576
	LimitNPROC=1048576
	LimitCORE=infinity
	MountFlags=slave

	# set up the bridge
	ExecStartPre=/usr/sbin/brctl addbr \${BRIDGE}
	ExecStartPre=/usr/sbin/ip addr add \${FLANNEL_SUBNET} dev \${BRIDGE}
	ExecStartPre=/usr/sbin/ip link set dev \${BRIDGE} up
	#
	# clean up bridge afterwards
	ExecStopPost=/usr/sbin/ip link set dev \${BRIDGE} down
	ExecStopPost=/usr/sbin/brctl delbr \${BRIDGE}

	[Install]
	WantedBy=multi-user.target
EOF

	systemctl daemon-reload

        # Configure proxy if there is one
        if [ ! -z $PROXY ]; then echo "Adding proxy"; X="-x $PROXY"; git config --global http.proxy "$PROXY"; fi

	# Install dependencies 
        cd $GIT_HOME
	rm -rf etcd etcd.tar.gz flannel flannel.tar.gz go.tar.gz kubernetes ${LOG_DIR}
        curl $X -L $ETCD_DL -o etcd.tar.gz; tar -xzf etcd.tar.gz; mv etcd-v2.0.11-linux-amd64 etcd
        curl $X -L $GO_DL -o go.tar.gz; tar -C /usr/local -xzf go.tar.gz
        curl $X -L $FLANNEL_DL -o flannel.tar.gz; tar -xzf flannel.tar.gz; mv flannel-0.4.1 flannel
        git clone $KUBERNETES_GIT kubernetes

	# Update PATH
	sed -i "/kubernetes/d" /root/.bash_profile
        sed -i "$ i  PATH=$PATH:/usr/local/go/bin:${GIT_HOME}/etcd:${GIT_HOME}/kubernetes/cluster:${GIT_HOME}/kubernetes/hack:${GIT_HOME}/flannel" /root/.bash_profile

        # Add to startup
        if [[ ! $(grep kube /etc/rc.local) ]]; then echo "${GIT_HOME}/kube-master.sh > /tmp/kube-master.log 2>&1" >> /etc/rc.local; fi
	chmod a+x /etc/rc.local
        systemctl start rc-local
fi

# Terminate the runing processes if any
echo "Clearing the environment..."
pkill kubelet
pkill kube-proxy
pkill kube-scheduler
pkill kube-controller-manager 
pkill kube-apiserver
pkill docker
pkill flanneld
pkill etcd

# Initialize 
echo "Initializing..."
cd "${KUBE_ROOT}"
source /root/.bash_profile 
source "${KUBE_ROOT}/hack/lib/init.sh"
"${KUBE_ROOT}/hack/build-go.sh"

# Start etcd
echo "Starting etcd..."
mkdir -p ${GIT_HOME}/etcd-data
${GIT_HOME}/etcd/etcd --data-dir ${GIT_HOME}/etcd-data --listen-client-urls "http://${API_HOST}:2379,http://${API_HOST}:4001" --advertise-client-urls "http://${API_HOST}:2379,http://${API_HOST}:4001"  > ${LOG_DIR}/etcd.log 2>&1  &
sleep 1

# Start flanneld
echo "Config subnet for flanneld..."
cat > flannel-config.json <<EOF
{
  "Network": "${FLANNEL_NETWORK}",
  "SubnetLen": 24,
  "Backend": {
    "Type": "vxlan",
    "VNI": 1
     }
}
EOF

curl -L http://${API_HOST}:4001/v2/keys/coreos.com/network/config -XPUT --data-urlencode value@flannel-config.json > ${LOG_DIR}/flanneld-config.log 2>&1 &

echo "Starting flanneld..."
${GIT_HOME}/flannel/flanneld -etcd-endpoints="http://${API_HOST}:4001" -etcd-prefix="/coreos.com/network" -iface="ens32" > ${LOG_DIR}/flanneld.log 2>&1 &

# Waiting flanned to finish
while [ ! -f /run/flannel/subnet.env ]; do sleep 1; echo "waiting flaneld to be ready..."; done

# Start docker
echo "Starting docker..."
systemctl restart docker.service

# Start kube-api server
echo "Starting kube-api server..."
"${GO_OUT}/kube-apiserver" --v="${LOG_LEVEL}" \
	--admission_control="NamespaceLifecycle,NamespaceAutoProvision,LimitRanger,ResourceQuota" \
	--insecure-bind-address="${API_HOST}" --insecure-port="${API_PORT}" --runtime_config="api/v1beta3" \
	--etcd_servers="http://${API_HOST}:4001" --portal_net="${KUBE_NETWORK}" >"${LOG_DIR}/kube-apiserver.log" 2>&1 &
echo api server pid is $!

# Wait for kube-apiserver to come up before launching the rest of the components.
echo "Waiting for apiserver to come up..."
kube::util::wait_for_url "http://${API_HOST}:${API_PORT}/api/v1beta3/pods" "apiserver: " 1 10 || exit 1

# Start kube-controller-manager
echo "Starting kube-controller-manager..."
"${GO_OUT}/kube-controller-manager" \
  --v=${LOG_LEVEL} \
  --address="0.0.0.0" \
  --master="${API_HOST}:${API_PORT}" >"${LOG_DIR}/kube-controller-manager.log" 2>&1 &
echo controll manager pid is $!

# Start kube-scheduler
echo "Starting kube-scheduler..."
"${GO_OUT}/kube-scheduler" \
  --v=${LOG_LEVEL} \
  --master="http://${API_HOST}:${API_PORT}" >"${LOG_DIR}/kube-scheduler.log" 2>&1 &
echo scheduler pid is $!

date > ${GIT_HOME}/.kubeinstalled

#################################################################
# Enable the following if you want the master also to be a node #
#################################################################
# Start Kubelet
echo "Starting kubelet..."
"${GO_OUT}/kubelet" \
  --v=${LOG_LEVEL} \
  --chaos_chance="${CHAOS_CHANCE}" \
  --address="0.0.0.0" \
  --api_servers="${API_HOST}:${API_PORT}" \
  --port="$KUBELET_PORT" >"${LOG_DIR}/kubelet.log" 2>&1 &
echo kubelet pid is $!

# Start Kubelet-proxy
echo "Starting kubelet-proxy..."
"${GO_OUT}/kube-proxy" \
  --v=${LOG_LEVEL} \
  --master="http://${API_HOST}:${API_PORT}" >"${LOG_DIR}/kube-proxy.log" 2>&1 &
echo kube-proxy pid is $!

cat <<EOF

To use your cluster, you need to run:

  source /root/.bash_profile 
  kubectl.sh config set-cluster my-cluster --server=http://${API_HOST}:${API_PORT} --insecure-skip-tls-verify=true
  kubectl.sh config set-context my-cluster --cluster=my-cluster
  kubectl.sh config use-context my-cluster

Kubectl examples:

  kubectl.sh get nodes # Check the nodes
  kubectl.sh get pods  # Check pods
  kubectl.sh get rc    # Check replication controller
  kubctl.sh get svc    # Check services

EOF

