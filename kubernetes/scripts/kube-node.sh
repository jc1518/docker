#!/bin/bash
# Kubernetes cluster node

# Define master host
KUBE_MASTER="dockerdev02.dmz.local"

# Set proxy if needed
PROXY=""

# Git repo 
GO_DL="https://storage.googleapis.com/golang/go1.4.2.linux-amd64.tar.gz"
KUBERNETES_GIT="https://github.com/GoogleCloudPlatform/kubernetes.git"
FLANNEL_GIT="https://github.com/coreos/flannel.git"

# Suggest not to change the following 
GIT_HOME="/root"
FLANNEL_NETWORK="172.16.0.0/16"
KUBE_ROOT="{GIT_HOME}/kubernetes"
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
        # Configure proxy if there is one
        if [ ! -z $PROXY ]; then echo "Adding proxy"; X="-x $PROXY"; git config --global http.proxy "$PROXY"; fi

	# Install dependencies 
        cd $GIT_HOME
        curl $X -L $GO_DL -o go.tar.gz; tar -C /usr/local -xzf go.tar.gz
        git clone $KUBERNETES_GIT kubernetes
        git clone $FLANNEL_GIT flannel
 
 	# Update PATH
        sed -i "$ i PATH=$PATH:/usr/local/go/bin:${GIT_HOME}/kubernetes/cluster:${GIT_HOME}/kubernetes/hack;${GIT_HOME}/flannel/bin" /root/.bash_profile

	# Add to startup
	if [[ ! $(grep kube /etc/rc.local) ]]; then echo "${GIT_HOME}/kube-node.sh > /tmp/kube-node.log 2>&1"; fi
	systemctl start rc-local
	systemctl enable rc-local
fi

# Terminate the runing processes if any
pkill kubelet
pkill kube-proxy
systemctl stop docker.service
pkill flanneld

# Initialize 
echo "Initializing..."
cd "${KUBE_ROOT}"
source /root/.bash_profile 
source "${KUBE_ROOT}/hack/lib/init.sh"
"${KUBE_ROOT}/hack/build-go.sh"

# Start flanneld
echo "Starting flanneld..."
${GIT_HOME}/flannel/bin/flanneld -etcd-endpoints="http://${API_HOST}:4001" -etcd-prefix="/coreos.com/network" -iface="ens32" > ${LOG_DIR}/flanneld.log 2>&1 &

# Waiting flanned to finish
while [ ! -f /run/flannel/subnet.env ]; do sleep 1; echo "waiting flaneld to be ready..."; done

# Start docker
echo "Starting docker..."
systemctl start docker.service

# Start Kubelet
echo "Starting kubelet..."
"${GO_OUT}/kubelet" \
  --v=${LOG_LEVEL} \
  --chaos_chance="${CHAOS_CHANCE}" \
  --hostname_override=`hostname` \
  --address="0.0.0.0" \
  --api_servers="${API_HOST}:${API_PORT}" \
  --auth_path="${KUBE_ROOT}/hack/.test-cmd-auth" \
  --port="$KUBELET_PORT" >"${LOG_DIR}/kubelet.log" 2>&1 &
echo kubelet pid is $!

# Start Kubelet-proxy
echo "Starting kubelet-proxy..."
"${GO_OUT}/kube-proxy" \
  --v=${LOG_LEVEL} \
  --master="http://${API_HOST}:${API_PORT}" >"${LOG_DIR}/kube-proxy.log" 2>&1 &
echo kube-proxy pid is $!

date > ${GIT_HOME}/.kubeinstalled


