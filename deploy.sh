#!/bin/bash
#
# Copyright (c) 2020, 2021 Red Hat, IBM Corporation and others.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

ROOT_DIR="${PWD}"
SCRIPTS_DIR="${ROOT_DIR}/scripts"

AUTOTUNE_DIR="./manifests/autotune"
PERF_PROFILE_CRD="${AUTOTUNE_DIR}/performance-profiles"
CRC_DIR="./manifests/crc"

AUTOTUNE_OPERATOR_CRD="${AUTOTUNE_DIR}/autotune-operator-crd.yaml"
AUTOTUNE_CONFIG_CRD="${AUTOTUNE_DIR}/autotune-config-crd.yaml"
AUTOTUNE_QUERY_VARIABLE_CRD="${AUTOTUNE_DIR}/autotune-query-variable-crd.yaml"
AUTOTUNE_PERF_PROFILE_CRD="${PERF_PROFILE_CRD}/kruize-performance-profile-crd.yaml"
AUTOTUNE_PERF_PROFILE_ROS="${PERF_PROFILE_CRD}/resource_optimization_openshift.yaml"
AUTOTUNE_DEPLOY_MANIFEST_TEMPLATE="${AUTOTUNE_DIR}/autotune-operator-deployment.yaml_template"
AUTOTUNE_DEPLOY_OPENSHIFT_MANIFEST_TEMPLATE="${AUTOTUNE_DIR}/autotune-operator-openshift-deployment.yaml_template"
AUTOTUNE_DEPLOY_MANIFEST="${AUTOTUNE_DIR}/autotune-operator-deployment.yaml"
AUTOTUNE_RB_MANIFEST_TEMPLATE="${AUTOTUNE_DIR}/autotune-operator-rolebinding.yaml_template"
AUTOTUNE_RB_MANIFEST="${AUTOTUNE_DIR}/autotune-operator-rolebinding.yaml"
AUTOTUNE_ROLE_MANIFEST="${AUTOTUNE_DIR}/autotune-operator-role.yaml"
AUTOTUNE_SA_MANIFEST="${AUTOTUNE_DIR}/autotune-operator-sa.yaml"
SERVICE_MONITOR_MANIFEST="${AUTOTUNE_DIR}/servicemonitor/autotune-service-monitor.yaml"
AUTOTUNE_OPENSHIFT_NAMESPACE="openshift-tuning"
AUTOTUNE_SA_NAME="autotune-sa"
AUTOTUNE_CONFIGMAPS="${AUTOTUNE_DIR}/configmaps"
AUTOTUNE_CONFIGS="${AUTOTUNE_DIR}/autotune-configs"
AUTOTUNE_QUERY_VARIABLES_MANIFEST_TEMPLATE="${AUTOTUNE_DIR}/autotune-query-variables/query-variable.yaml_template"
AUTOTUNE_QUERY_VARIABLES_MANIFEST="${AUTOTUNE_DIR}/autotune-query-variables/query-variable.yaml"
KRUIZE_DEPLOY_MANIFEST_OPENSHIFT="${CRC_DIR}/kruize-crc-openshift.yaml"
KRUIZE_DEPLOY_MANIFEST_MINIKUBE="${CRC_DIR}/kruize-crc-minikube.yaml"

AUTOTUNE_PORT="8080"
AUTOTUNE_DOCKER_REPO="docker.io/kruize/autotune_operator"
#Fetch autotune version from the pom.xml file.
AUTOTUNE_VERSION="$(grep -A 1 "autotune" "${ROOT_DIR}"/pom.xml | grep version | awk -F '>' '{ split($2, a, "<"); print a[1] }')"
AUTOTUNE_DOCKER_IMAGE=${AUTOTUNE_DOCKER_REPO}:${AUTOTUNE_VERSION}
HPO_DOCKER_REPO="docker.io/kruize/hpo"
# From the kruize/hpo repo
HPO_VERSION=0.0.2
HPO_DOCKER_IMAGE=${HPO_DOCKER_REPO}:${HPO_VERSION}

# source all the helpers scripts
. ${SCRIPTS_DIR}/minikube-helpers.sh
. ${SCRIPTS_DIR}/openshift-helpers.sh
. ${SCRIPTS_DIR}/common_utils.sh

# Defaults for the script
# minikube is the default cluster type
cluster_type="minikube"
# Call setup by default (and not terminate)
setup=1
# Default mode is interactive
non_interactive=0
autotune_ns=""
target="autotune"
# docker: loop timeout is turned off by default
timeout=-1

function ctrlc_handler() {
	# Check if cluster type is docker
	if [[ "$cluster_type" == "docker" ]]; then
		# Terminate the containers [autotune && grafana && prometheus && cadvisor]
		docker_terminate
	fi
	# Exiting gracefully
	exit 2
}

# Handle SIGHUP(1), SIGINT(2), SIGQUIT(3) for cleaning up containers in docker case
trap "ctrlc_handler" 1 2 3

function usage() {
	echo
	echo "Usage: $0 [-a] [-k url] [-c [docker|minikube|openshift]] [-i autotune docker image] [-o hpo docker image] [-n namespace] [-d configmaps-dir ] [--timeout=x, x in seconds, for docker only]"
	echo "       -s = start(default), -t = terminate"
	echo " -s: Deploy autotune [Default]"
	echo " -t: Terminate autotune deployment"
	echo " -c: kubernetes cluster type. At present we support only minikube [Default - minikube]"
	echo " -i: build with specific autotune operator docker image name [Default - kruize/autotune_operator:<version from pom.xml>]"
	echo " -o: build with specific hpo docker image name [Default - kruize/hpo:0.0.2]"
	echo " -n: Namespace to which autotune is deployed [Default - monitoring namespace for cluster type minikube]"
	echo " -d: Config maps directory [Default - manifests/configmaps]"
	echo " -m: Target mode selection [autotune | crc]"
	exit -1
}

# Check if the cluster_type is one of icp or openshift
function check_cluster_type() {
	case "${cluster_type}" in
	docker|minikube|openshift)
		;;
	*)
		echo "Error: unsupported cluster type: ${cluster_type}"
		exit -1
	esac
}

# Iterate through the commandline options
while getopts ac:d:i:k:m:n:o:p:stu:-: gopts
do
	case ${gopts} in
	-)
		case "${OPTARG}" in
			timeout=*)
				timeout=${OPTARG#*=}
				if [ -z "${timeout}" ]; then
					usage
				fi
				;;
			*)
				if [ "${OPTERR}" == 1 ] && [ "${OPTSPEC:0:1}" != ":" ]; then
					echo "Unknown option --${OPTARG}" >&2
					usage
				fi
				;;
		esac
		;;
	a)
		non_interactive=1
		;;
	c)
		cluster_type="${OPTARG}"
		check_cluster_type
		;;
	d)
		AUTOTUNE_CONFIGMAPS="${OPTARG}"
		;;
	i)
		AUTOTUNE_DOCKER_IMAGE="${OPTARG}"
		;;
	k)
		kurl="${OPTARG}"
		;;
  m)
		target="${OPTARG}"
		;;
	n)
		autotune_ns="${OPTARG}"
		;;
	o)
		HPO_DOCKER_IMAGE="${OPTARG}"
		;;
	s)
		setup=1
		;;
	t)
		setup=0
		;;
	[?])
		usage
	esac
done

# Call the proper setup function based on the cluster_type
if [ ${setup} == 1 ]; then
	if [ ${target} == "crc" ]; then
		if [ ${cluster_type} == "minikube" ] || [ ${cluster_type} == "openshift" ]; then
			if [ ${cluster_type} == "minikube" ]; then
				MANIFEST_FILE=$KRUIZE_DEPLOY_MANIFEST_MINIKUBE
				autotune_ns="monitoring"
			fi

			if [ ${cluster_type} == "openshift" ]; then
				MANIFEST_FILE=$KRUIZE_DEPLOY_MANIFEST_OPENSHIFT
				autotune_ns="openshift-tuning"
			fi

			MANIFEST_FILE_OLD="/tmp/kruize.yaml"

			cp $MANIFEST_FILE $MANIFEST_FILE_OLD
			KRUIZE_VERSION="$(grep -A 1 "autotune" pom.xml | grep version | awk -F '>' '{ split($2, a, "<"); print a[1] }')"
			sed -e "s/image: \"kruize\/autotune_operator:${KRUIZE_VERSION}\"/image: \"${AUTOTUNE_DOCKER_IMAGE//\//\\\/}\"/g" ${MANIFEST_FILE_OLD} > ${MANIFEST_FILE}

			kubectl apply -f ${MANIFEST_FILE}
			check_running kruize ${autotune_ns}
			if [ "${err}" != "0" ]; then
				# Indicate deploy failed on error
				exit 1
			fi
			cp ${MANIFEST_FILE_OLD} ${MANIFEST_FILE}
		else
			echo "Unsupported cluster!"
		fi
	else
		${cluster_type}_start
	fi
else
	if [ ${target} == "crc" ]; then
		${cluster_type}_crc_terminate
	else
		${cluster_type}_terminate
	fi
fi
