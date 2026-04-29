vrrp_script check_apiserver {
    script "/bin/bash -c 'echo > /dev/tcp/127.0.0.1/6443'"
    interval 5
    fall 2
    rise 2
}

vrrp_instance k0s_api {
    state ${state}
    interface eth0
    virtual_router_id 51
    priority ${priority}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass k0svip1
    }
    virtual_ipaddress {
        192.168.1.200/24
    }
    track_script {
        check_apiserver
    }
}
