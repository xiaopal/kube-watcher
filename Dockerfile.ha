FROM alpine:3.7

RUN apk add --no-cache bash coreutils curl openssh-client openssl git findutils && \
	curl -sSL "http://npc.nos-eastchina1.126.net/dl/dumb-init_1.2.0_amd64.tar.gz" | tar -zx -C /usr/local/bin && \
	curl -sSL 'http://npc.nos-eastchina1.126.net/dl/jq_1.5_linux_amd64.tar.gz' | tar -zx -C /usr/local/bin && \
	curl -sSL 'https://npc.nos-eastchina1.126.net/dl/kubernetes-client-v1.9.3-linux-amd64.tar.gz' | tar -zx -C /usr/local && \
	ln -s /usr/local/kubernetes/client/bin/kubectl /usr/local/bin/kubectl && \
	curl -sSL 'https://raw.githubusercontent.com/xiaopal/kube-leader-elect/master/kube-leader-elect.sh' >/usr/local/bin/kube-leader-elect && \
	chmod 755 /usr/local/bin/kube-leader-elect

ADD kube-watcher.sh /usr/local/kube-watcher.sh
RUN chmod 755 /usr/local/kube-watcher.sh && ln -s /usr/local/kube-watcher.sh /usr/local/bin/kube-watcher

ENV LEADER_LIFETIME=${LEADER_LIFETIME:-90} \
    LEADER_RENEW="${LEADER_RENEW:-30}" \
    LEADER_HOLDER="${LEADER_HOLDER:-configmap/kube-watcher.leader}" \
    MEMBER="${MEMBER:-$HOSTNAME}"

ENTRYPOINT ["/usr/local/bin/dumb-init",  "kube-leader-elect", "/usr/local/bin/dumb-init", "kube-watcher" ]
