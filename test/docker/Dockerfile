# sshd for functional tests. The Rakefile's test:docker task generates a
# throwaway key and copies its public half here as authorized_keys.
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server sudo \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash deployer \
 && echo "deployer ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deployer \
 && mkdir -p /run/sshd \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >> /etc/ssh/sshd_config
COPY authorized_keys /home/deployer/.ssh/authorized_keys
RUN chown -R deployer:deployer /home/deployer/.ssh \
 && chmod 700 /home/deployer/.ssh \
 && chmod 600 /home/deployer/.ssh/authorized_keys
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
