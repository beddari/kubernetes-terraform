data "template_file" "lb_labels" {
    template = "lb=true"
    count = "${var.lb_count}"
}

data "template_file" "worker_labels" {
    template = ""
    count = "${var.worker_count - var.lb_count}"
}

data "template_file" "kubelet-worker-service" {
    count = "${var.worker_count}"

    template = "${file("${path.module}/templates/kubelet.service")}"
    vars {
        kubeconfig_path = "/etc/kubernetes/worker-kubeconfig.yaml"
        k8s_ver = "${var.k8s_version}"
        network_plugin = ""
        dns_service_ip = "${var.dns_service_ip}"
        hostname_override = "${element(openstack_compute_instance_v2.kube.*.network.0.fixed_ip_v4, count.index)}"
        labels = "${element(concat(data.template_file.lb_labels.*.rendered, data.template_file.worker_labels.*.rendered), count.index)}"
    }
}

data "template_file" "kube-proxy-worker-yaml" {
    template = "${file("${path.module}/templates/kube-proxy-worker.yaml")}"
    vars {
        k8s_ver = "${var.k8s_version}"
    }
}

data "template_file" "worker-kubeconfig" {
    template = "${file("${path.module}/templates/worker-kubeconfig.yaml")}"
    vars {
        cluster_name = "${var.cluster_name}"
    }
}

data "template_file" "haproxy-apiserver-cfg" {
    template = "${file("${path.module}/templates/haproxy-apiserver.cfg")}"
    vars {
        masters_txt = "${join("\n  ", formatlist("server %s %s:443", openstack_compute_instance_v2.kube-apiserver.*.name, openstack_compute_instance_v2.kube-apiserver.*.network.0.fixed_ip_v4))}"
    }
}

resource "tls_private_key" "kube_etcd_client" {
    count = "${var.worker_count}"
    algorithm = "ECDSA"
}

resource "tls_cert_request" "kube_etcd_client" {
    count = "${var.worker_count}"
    key_algorithm = "${element(tls_private_key.kube_etcd_client.*.algorithm, count.index)}"
    private_key_pem = "${element(tls_private_key.kube_etcd_client.*.private_key_pem, count.index)}"

    subject {
        common_name = "${var.cluster_name}-kube-${count.index}"
    }
}

resource "tls_locally_signed_cert" "kube_etcd_client" {
    count = "${var.worker_count}"
    cert_request_pem = "${element(tls_cert_request.kube_etcd_client.*.cert_request_pem, count.index)}"

    ca_key_algorithm = "${tls_private_key.etcd_ca.algorithm}"
    ca_private_key_pem = "${tls_private_key.etcd_ca.private_key_pem}"
    ca_cert_pem = "${tls_self_signed_cert.etcd_ca.cert_pem}"

    validity_period_hours = 175320 # About 20 years

    allowed_uses = [
        "digital_signature",
        "key_encipherment",
        "client_auth",
    ]
}

resource "tls_private_key" "kube_apiserver_client" {
    count = "${var.worker_count}"
    algorithm = "ECDSA"
}

resource "tls_cert_request" "kube_apiserver_client" {
    count = "${var.worker_count}"
    key_algorithm = "${element(tls_private_key.kube_apiserver_client.*.algorithm, count.index)}"
    private_key_pem = "${element(tls_private_key.kube_apiserver_client.*.private_key_pem, count.index)}"

    subject {
        common_name = "kube-worker-${count.index}"
        organization = "worker"
    }
}

resource "tls_locally_signed_cert" "kube_apiserver_client" {
    count = "${var.worker_count}"
    cert_request_pem = "${element(tls_cert_request.kube_apiserver_client.*.cert_request_pem, count.index)}"

    ca_key_algorithm = "${tls_private_key.kubernetes_ca.algorithm}"
    ca_private_key_pem = "${tls_private_key.kubernetes_ca.private_key_pem}"
    ca_cert_pem = "${tls_self_signed_cert.kubernetes_ca.cert_pem}"

    validity_period_hours = 175320 # About 20 years

    allowed_uses = [
        "digital_signature",
        "key_encipherment",
        "client_auth",
    ]
}

resource "openstack_compute_servergroup_v2" "workers" {
    name = "${var.cluster_name}-workers"
    policies = ["anti-affinity"]
}

data "template_file" "lb_sec_group" {
    template = "${join(",", var.lb_sec_groups)}"
    count = "${var.lb_count}"
}

data "template_file" "worker_sec_group" {
    template = "${join(",", var.worker_sec_groups)}"
    count = "${var.worker_count - var.lb_count}"
}

resource "openstack_compute_instance_v2" "kube" {
    #   Create as many worker instances as needed
    count = "${var.worker_count}"

    name = "${var.cluster_name}-kube-${count.index}"
    region = "${var.region}"
    image_id = "${var.images["coreos"]}"
    flavor_name = "${var.worker_flavor}"
    key_pair = "${var.ssh_key["name"]}"
    security_groups = ["${split(",",element(concat(data.template_file.lb_sec_group.*.rendered, data.template_file.worker_sec_group.*.rendered), count.index))}"]

    scheduler_hints {
        group = "${openstack_compute_servergroup_v2.workers.id}"
    }

    #   Connecting to the set network with the provided floating ip.
    network {
        name = "kubes"
        floating_ip = "${element(openstack_compute_floatingip_v2.kube_flip.*.address, count.index)}"
    }

}

resource "null_resource" "kube" {
    count = "${var.worker_count}"

    # Add etcd certs & key
    provisioner "remote-exec" {
        inline = [
            "mkdir -p /tmp/etcd",
        ]
    }
    provisioner "file" {
        destination = "/tmp/etcd/ca.pem"
        content = "${tls_self_signed_cert.etcd_ca.cert_pem}"
    }
    provisioner "file" {
        destination = "/tmp/etcd/node.pem"
        content = "${element(tls_locally_signed_cert.kube_etcd_client.*.cert_pem, count.index)}"
    }
    provisioner "file" {
        destination = "/tmp/etcd/node-key.pem"
        content = "${element(tls_private_key.kube_etcd_client.*.private_key_pem, count.index)}"
    }
    provisioner "remote-exec" {
        inline = [
            "sudo rm -rf /etc/ssl/etcd",
            "sudo chown -R root:root /tmp/etcd",
            "sudo mv /tmp/etcd /etc/ssl/",
        ]
    }

    provisioner "remote-exec" {
        inline = [
            "sudo mkdir -p /etc/kubernetes/ssl",
            "sudo mkdir /etc/kubernetes/manifests",
            "sudo chmod -R ugo+w /etc/kubernetes",
            "sudo mkdir -p /etc/flannel",
            "sudo chmod ugo+w /etc/flannel",
            "sudo chmod -R ugo+w /etc/systemd",
            "sudo chmod ugo+w /etc/kubernetes",
            "sudo mkdir -p /etc/systemd/system/flanneld.service.d",
            "sudo chmod ugo+w /etc/systemd/system/flanneld.service.d",
        ]
    }

    provisioner "file" {
        destination = "/etc/kubernetes/ssl/ca.pem"
        content = "${tls_self_signed_cert.kubernetes_ca.cert_pem}"
    }

    provisioner "file" {
        destination = "/etc/kubernetes/ssl/worker.pem"
        content = "${element(tls_locally_signed_cert.kube_apiserver_client.*.cert_pem, count.index)}"
    }

    provisioner "file" {
        destination = "/etc/kubernetes/ssl/worker-key.pem"
        content = "${element(tls_private_key.kube_apiserver_client.*.private_key_pem, count.index)}"
    }

    provisioner "file" {
        destination = "/etc/flannel/options.env"
        content = "FLANNELD_IFACE=${element(openstack_compute_instance_v2.kube.*.network.0.fixed_ip_v4, count.index)}\nFLANNELD_ETCD_ENDPOINTS=${join(",", formatlist("https://%s:%s", openstack_compute_instance_v2.etcd.*.network.0.fixed_ip_v4, var.etcd_port))}\nFLANNELD_ETCD_CAFILE=/etc/ssl/etcd/ca.pem\nFLANNELD_ETCD_CERTFILE=/etc/ssl/etcd/node.pem\nFLANNELD_ETCD_KEYFILE=/etc/ssl/etcd/node-key.pem\n"
    }

    provisioner "file" {
        destination = "/etc/systemd/system/flanneld.service.d/40-ExecStartPre-symlink.conf"
        content = "[Service]\nExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env\n"
    }

    provisioner "file" {
        destination = "/etc/systemd/system/docker.service.d/40-flannel.conf"
        content = "[Unit]\nRequires=flanneld.service\nAfter=flanneld.service"
    }

    provisioner "file" {
        destination = "/etc/systemd/system/kubelet.service"
        content = "${element(data.template_file.kubelet-worker-service.*.rendered, count.index)}\n"
    }

    provisioner "file" {
        destination = "/etc/kubernetes/worker-kubeconfig.yaml"
        content = "${data.template_file.worker-kubeconfig.rendered}"
    }

    provisioner "file" {
        destination = "/etc/kubernetes/manifests/kube-proxy.yaml"
        content = "${element(data.template_file.kube-proxy-worker-yaml.*.rendered, count.index)}\n"
    }

    provisioner "file" {
        destination = "/etc/kubernetes/manifests/kube-proxy.yaml"
        content = "${element(data.template_file.kube-proxy-worker-yaml.*.rendered, count.index)}\n"
    }

    provisioner "file" {
        destination = "/etc/kubernetes/manifests/haproxy-apiserver.yaml"
        source = "${path.module}/templates/haproxy-apiserver.yaml"
    }

    provisioner "file" {
        destination = "/etc/kubernetes/haproxy-apiserver.cfg"
        content = "${data.template_file.haproxy-apiserver-cfg.rendered}\n"
    }

#   Transfer keys and config files to the workers
    provisioner "remote-exec" {
        inline = [
            "sudo chmod 600 /etc/kubernetes/ssl/*-key.pem",
            "sudo chown root:root /etc/kubernetes/ssl/*-key.pem",
            "sudo ln -s kube-worker-${count.index}-worker.pem worker.pem",
            "sudo ln -s kube-worker-${count.index}-worker-key.pem worker-key.pem",

            "sudo systemctl daemon-reload",
            "sudo systemctl start flanneld",
            "sudo systemctl start kubelet",
            "sudo systemctl enable flanneld",
            "sudo systemctl enable kubelet"
        ]
    }

    # Configure locksmithd for coordinated reboot of the nodes.
    provisioner "file" {
        destination = "/tmp/locksmithd.conf"
        content = "${data.template_file.locksmithd.rendered}"
    }
    provisioner "remote-exec" {
        inline = [
            "sudo mkdir -p /etc/systemd/system/locksmithd.service.d",
            "sudo chown -R root:root /tmp/locksmithd.conf",
            "sudo mv /tmp/locksmithd.conf /etc/systemd/system/locksmithd.service.d/",
            "sudo systemctl daemon-reload",
            "sudo systemctl restart locksmithd",
        ]
    }

    #   Tells Terraform how to connect to instances of this type.
    #   The floating ip is the same one given to 'network'.
    #   'file(...)' loads the private key, and gives it to Terraform for secure connection.
    connection {
        user = "core"
        host = "${element(openstack_compute_floatingip_v2.kube_flip.*.address, count.index)}"
        private_key = "${file(var.ssh_key["private"])}"
        access_network = true
    }

    #   This resource can't be initialized until the given resources has completed.
    depends_on = [
        "null_resource.flannel_config",
    ]
}

resource "openstack_compute_floatingip_v2" "kube_flip" {
    #   Pull y floating ips from the given ip-pool, where y is the number of worker instances.
    count = "${var.worker_count}"

    region = "${var.region}"
    pool = "public-v4"
}
