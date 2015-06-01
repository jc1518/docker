#!/bin/bash
# version 1.0 - 29/05/2015

# Define where to save sources 
GIT_HOME="/root"

# Set proxy if needed
PROXY=""

# Git repo 
ETCD_DL="https://github.com/coreos/etcd/releases/download/v2.0.11/etcd-v2.0.11-linux-amd64.tar.gz"
GO_DL="https://storage.googleapis.com/golang/go1.4.2.linux-amd64.tar.gz"
KUBERNETES_GIT="https://github.com/GoogleCloudPlatform/kubernetes.git"
FLANNEL_GIT="https://github.com/coreos/flannel.git"
SCRIPT_MASTER="https://raw.githubusercontent.com/jc1518/docker/master/kubernetes/scripts/kube-master.sh"
SCRIPT_NODE="https://raw.githubusercontent.com/jc1518/docker/master/kubernetes/scripts/kube-node.sh"

if [ -z $1 ] || [ $1 != master ] && [ $1 != node ]; then
	echo "Usage: `basename $0` master|node"
	exit 1
fi

# Configure proxy if there is one
if [ ! -z $PROXY ]; then export http_proxy="$PROXY"; git config --global http.proxy "$PROXY"; fi

# Install dependencies 
yum -y install git curl gcc docker 

# Download common source codes
cd $GIT_HOME
curl -L $GO_DL -o go.tar.gz; tar -C /usr/local -xzf go.tar.gz
git clone $KUBERNETES_GIT kubernetes
git clone $FLANNEL_GIT flannel

if [ $1 == "master" ]; then
	# Download etcd for cluster master 
	curl -L $ETCD_DL -o etcd.tar.gz; tar xvzf etcd.tar.gz
	# Update PATH
	sed -i "$ i PATH=$PATH:/usr/local/go/bin:${GIT_HOME}/etcd:${GIT_HOME}/kubernetes/cluster:${GIT_HOME}/kubernetes/hack;${GIT_HOME}/flannel/bin" /root/.bash_profile
	# Download kube-master.sh
	curl -L $SCRIPT_MASTER -o kube-master.sh
	chmod a+x kube-master.sh
	echo "Defind KUBE-MASTER and KUBE-NODES in ${GIT_HOME}/kube-master.sh"
fi

if [ $1 == "node" ]; then
	# Update PATH
	sed -i "$ i PATH=$PATH:/usr/local/go/bin:${GIT_HOME}/kubernetes/cluster:${GIT_HOME}/kubernetes/hack;${GIT_HOME}/flannel/bin" /root/.bash_profile
	# Download kube-master.sh
	curl -L $SCRIPT_MASTER -o kube-node.sh
	chmod a+x kube-node.sh
	echo "Defind KUBE-MASTER in ${GIT_HOME}/kube-node.sh"
fi


