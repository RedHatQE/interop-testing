FROM registry.access.redhat.com/ubi9:latest

ARG OCP_VERSION=latest

RUN curl -L https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/${OCP_VERSION}/openshift-client-linux.tar.gz | tar -C /usr/bin -zxvf - oc
RUN dnf install -y make jq
