## whpg_coordinator_ha_v2
S-Core의 Kyuhwan Lee 님이 기여한 코드 입니다.

### setup keepalived at Coordinator and standby Coordinator
 ```
sudo dnf install -y keepalived 
 ```

(Optional) Some service need to bing VIP. no need if service start 0.0.0.0 for listen 
 ```
echo "net.ipv4.ip_nonlocal_bind = 1" | sudo tee -a /etc/sysctl.conf # Allow VIP to not be bound locally
sudo sysctl -p
 ```

Allow VRRP protocol if firewall using <br>
 ```
sudo firewall-cmd --permanent --add-rich-rule='rule protocol value="vrrp" accept'
 ```
Allow specific multicast addresses (VRRP uses 224.0.0.18 multicast) if firewall using <br>
 ```
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" destination address="224.0.0.18" protocol="vrrp" accept'
sudo firewall-cmd --reload # Reload the firewall to apply the changes
 ```

### folder / files
 ```
/etc/keepalived/keepalived.conf     # keepalived.conf.master for MASTER, keepalived.conf.backup for BACKUP
/etc/keepalived/check_my_service.sh # check_my_service.sh.master for MASTER, check_my_service.sh.backup for BACKUP
/etc/keepalived/notify_master.sh
/etc/keepalived/notify_rejoin.sh
/etc/keepalived/notify_state_change.sh
/etc/keepalived/notify_switchover.sh
 ```
### change scripts
```
DB_HOST="cdw"        # hostname (or IP address)
DB_PORT="5432"       # port
DB_USER="gpadmin" 
VIP="192.168.56.100"
COORDINATOR_DATA_DIRECTORY="/data/coordinator/gpseg-1"
and so on.
```
### Change Owner and Permission
 ```
sudo chmod +x /etc/keepalived/*.sh
sudo chown gpadmin:gpadmin /etc/keepalived/*
sudo usermod -aG wheel gpadmin

sudo visudo          # add below for gpadmin account. 
gpadmin ALL=(gpadmin) NOPASSWD: /bin/bash
 ```

### Start Keepalived Service
 ```
sudo systemctl enable keepalived
sudo systemctl start keepalived
sudo systemctl reload keepalived    # after change configuration of keepalived
 ```
### Check Keepalived Service 
 ```
sudo systemctl status keepalived
sudo journalctl -u keepalived -f
 ```
### Check VIP 
 ```
nmcli connection show
ip a
ip a show [InterfaceName]

while true; do /usr/local/greenplum-db/bin/pg_isready -h <VIP> -d postgres -p 5432 -U gpadmin -t 1; date; echo ---------------------; sleep 1; done

while true; do psql -d postgres -h <VIP> -c "select count(*) from canary_queries;";date; echo ==========================; sleep 1; done
 ```
### Check VRRP Packet
 ```
sudo tcpdump -i [InterfaceName] vrrp
sudo tcpdump -i [InterfaceName] -n "proto 112"

sudo tcpdump -i [InterfaceName] ah             # for IPsec AH 
sudo tcpdump -i [InterfaceName] -n "proto 51"  # for IPsec AH 

ex)
sudo tcpdump -i eth1 vrrp
sudo tcpdump -i eth1 -n "proto 112"

sudo tcpdump -i eth1 ah
sudo tcpdump -i eth1 -n "proto 51"
 ```
### Check log messages
```
sudo grep Keepalived /var/log/messages
```

### Keepalived RPM Dependency.
```
libnl: A library that uses the Netlink protocol. It is essential for keepalived to handle the network interface and routing table information required to send and receive VRRP (Virtual Router Redundancy Protocol) messages.
libnfnetlink: A library used for features such as Netfilter connection tracking.
libmnl: A low-level library for handling Netlink messages.
openssl: An SSL/TLS protocol library. It may be required for keepalived's communication security or for certain authentication methods.
systemd: Required for managing keepalived as a system service. Systemd is responsible for starting, stopping, and restarting the keepalived process.
libcap: A library for process permissions management. It is used by keepalived to securely grant permissions for certain network operations.
popt: A library for parsing command-line options. It is required for keepalived to process various command-line arguments.
coreutils: A package containing core Linux utilities such as chown, chmod, and ln.

```

## Scenario : Failover 
```
if nopreempt mode in BACKUP, failover only at Server down, Interface down, except when DB down.
if preempt mode in BACKUP, failover at Server down, Interface down and DB down.

Failover means that BACKUP node will be Master node of WarehousePG and VIP also move to BACKUP node.

check at BACKUP node
 $ sudo ip a
 $ sudo systemctl status keepalived
 $ gpstate 
```

## Scenario : Restore Failed Node 
```
When failed node start up normaly, make it standby node of WarehousePG by following
1. At failed node
   check $COORDINATOR_DATA_DIRECTORY,
   and rm -rf $COORDINATOR_DATA_DIRECTORY or mv $COORDINATOR_DATA_DIRECTORY $COORDINATOR_DATA_DIRECTORY.org
2. At Backup node( currently Master node of WarehousePG )
   $ gpinitstandby -s failed_node_ip
```

## Scenario : Failback, return to original state
```
when master and standby is running, do following command at current Master node.
$ kill -9 postgres_pid
or
$ pg_ctl -D $COORDINATOR_DATA_DIRECTORY stop

then, ..
The keepalived move VIP to original master node and run gpactivatestandby at original master node

and then
make new standby node of WarehousePG at Master node.
$ gpinitstandby -s backup_node
```

## Keepalived Logging Setup
### 1. Change syslog facility to `local0`

```bash
sudo sed -i 's/KEEPALIVED_OPTIONS="-D"/KEEPALIVED_OPTIONS="-D -S 0"/g' /etc/sysconfig/keepalived
```

### 2. Add rsyslog routing rule

```bash
echo "local0.* /var/log/keepalived.log" | sudo tee /etc/rsyslog.d/keepalived.conf
echo "& stop" | sudo tee -a /etc/rsyslog.d/keepalived.conf
```

### 3. Add logrotate policy

```bash
cat <<EOF > /etc/logrotate.d/keepalived
/var/log/keepalived.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 0640 root root
    postrotate
        /usr/bin/systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
EOF
```

### Apply changes

```bash
sudo systemctl restart rsyslog
```
