#!/usr/bin/env bats
# Copyright (c) 2026 NVIDIA Corporation
#
# SPDX-License-Identifier: Apache-2.0
#
# Helm template tests for running several kata-deploy installations side by side
# (env.multiInstallSuffix). No cluster required.
#
# Everything that belongs to one installation is named after its suffix, but
# katacontainers.io/kata-runtime is not: every installation's RuntimeClasses select
# it, so it says "this node can run Kata", not "this installation is here". Each
# installation therefore also marks the nodes it holds with a label of its own, and
# an uninstall takes the shared label away only once no other mark is left. These
# tests check that both dispatchers are told which mark is theirs.

load "${BATS_TEST_DIRNAME}/../../common.bash"

source "${BATS_TEST_DIRNAME}/lib/helm-deploy.bash"

CHART_PATH="$(get_chart_path)"

render_dispatcher() {
	local stage="${1}"
	shift
	helm template kata-deploy "${CHART_PATH}" \
		--set deploymentMode=job \
		--show-only "templates/kata-deploy-${stage}-job.yaml" \
		"$@"
}

refute_match() {
	local rendered="${1}" pattern="${2}"
	if echo "${rendered}" | grep -q -- "${pattern}"; then
		echo "unexpected in rendered output: ${pattern}" >&2
		return 1
	fi
}

@test "Helm template (job mode): both dispatchers know which install they are" {
	local stage rendered
	for stage in install cleanup; do
		rendered=$(render_dispatcher "${stage}" --set env.multiInstallSuffix=dev)
		echo "${rendered}" | grep -q -- '--multi-install-suffix=dev'
	done
}

@test "Helm template (job mode): a single install needs no suffix to say so" {
	# The dispatcher falls back to the "default" instance, so the flag is only
	# rendered when there is something to say.
	local stage rendered
	for stage in install cleanup; do
		rendered=$(render_dispatcher "${stage}")
		refute_match "${rendered}" '--multi-install-suffix'
	done
}

@test "Helm template: the node label the RuntimeClasses select is never suffixed" {
	# Which is the whole reason the per-install mark exists: this label cannot tell
	# two installations apart, so it cannot be used to decide whether removing it is
	# safe.
	local rendered
	rendered=$(helm template kata-deploy "${CHART_PATH}" \
		--set deploymentMode=job \
		--set env.multiInstallSuffix=dev \
		--show-only templates/runtimeclasses.yaml)

	echo "${rendered}" | grep -q 'katacontainers.io/kata-runtime: "true"'
	refute_match "${rendered}" 'katacontainers.io/kata-runtime-dev'
}

@test "Helm template: an install's RuntimeClasses select its own mark as well" {
	# Without this, removing this install from a node would not stop its own
	# workloads being scheduled there: the shared label stays while another install
	# holds the node.
	local rendered
	rendered=$(helm template kata-deploy "${CHART_PATH}" \
		--set deploymentMode=job \
		--set env.multiInstallSuffix=dev \
		--show-only templates/runtimeclasses.yaml)

	echo "${rendered}" | grep -q 'kata-deploy.katacontainers.io/dev: "true"'
}

@test "Helm template: a single install's RuntimeClasses select the shared label only" {
	# One install cannot be outvoted about its own node, so demoting the shared
	# label is enough to stop its workloads - and adding a second selector would
	# strand them until an upgrade had marked every node.
	local rendered
	rendered=$(helm template kata-deploy "${CHART_PATH}" \
		--set deploymentMode=job \
		--show-only templates/runtimeclasses.yaml)

	echo "${rendered}" | grep -q 'katacontainers.io/kata-runtime: "true"'
	refute_match "${rendered}" 'kata-deploy.katacontainers.io/'
}

@test "Helm template: custom RuntimeClasses are gated on the mark too" {
	local rendered
	rendered=$(helm template kata-deploy "${CHART_PATH}" \
		--set deploymentMode=job \
		--set env.multiInstallSuffix=dev \
		--set customRuntimes.enabled=true \
		--set customRuntimes.runtimes.mine.baseConfig=qemu \
		--set-string customRuntimes.runtimes.mine.runtimeClass='kind: RuntimeClass
apiVersion: node.k8s.io/v1
metadata:
  name: mine
handler: mine
scheduling:
  nodeSelector:
    katacontainers.io/kata-runtime: "true"
' \
		--show-only templates/custom-runtimes.yaml)

	echo "${rendered}" | grep -q 'kata-deploy.katacontainers.io/dev: "true"'
	echo "${rendered}" | grep -q 'katacontainers.io/kata-runtime: "true"'
}
