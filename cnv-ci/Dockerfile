FROM registry.access.redhat.com/ubi9:latest

ARG OC_CLI_VERSION=latest

RUN curl -L https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/${OC_CLI_VERSION}/openshift-client-linux.tar.gz | tar -C /usr/bin -zxvf - oc
RUN dnf install -y --nodocs --setopt=install_weak_deps=False make jq unzip git && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" && \
      unzip "/tmp/awscliv2.zip" -d "/tmp" && \
      /tmp/aws/install --bin-dir "/usr/local/bin" --install-dir "/usr/local/aws-cli" && \
      rm -vrf "/tmp/aws" "/tmp/awscliv2.zip" 
