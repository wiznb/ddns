```
wget https://raw.githubusercontent.com/wiznb/ddns/refs/heads/main/ddns.sh && chmod +x ddns.sh && bash ddns.sh
```

选择 2 可以修改配置
选择 1 执行更新（首次会显示公网 IP、当前解析、成功与失败步骤）
配置会自动保存到：
/root/ddns/config.env（权限 600）

查看“只有 IP 变化才记录”的日志
tail -n 50 /root/ddns/ip_changes.log

设置 cron 每分钟跑（推荐）
```
crontab -e
```
```
* * * * * /bin/bash /root/ddns.sh --run
```
每分钟执行一次

运行输出（包含错误）会自动写到：/root/ddns/run.log

IP 只有变化才写：/root/ddns/ip_changes.log（只保留 30 天）

Debian/Ubuntu：apt-get update && apt-get install -y jq
CentOS：yum install -y jq 或 dnf install -y jq
Alpine：apk add jq
