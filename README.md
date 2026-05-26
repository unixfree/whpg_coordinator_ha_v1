# whpg_coordinator_ha_v1
S-Core LKH 님이 기여한 코크 입니다.

# Keepalived Logging Setup
## 1. Change syslog facility to `local0`

```bash
sudo sed -i 's/KEEPALIVED_OPTIONS="-D"/KEEPALIVED_OPTIONS="-D -S 0"/g' /etc/sysconfig/keepalived
```

## 2. Add rsyslog routing rule

```bash
echo "local0.* /var/log/keepalived.log" | sudo tee /etc/rsyslog.d/keepalived.conf
echo "& stop" | sudo tee -a /etc/rsyslog.d/keepalived.conf
```

## 3. Add logrotate policy

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

## Apply changes

```bash
sudo systemctl restart rsyslog
```
