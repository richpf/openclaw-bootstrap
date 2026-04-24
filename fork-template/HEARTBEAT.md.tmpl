# HEARTBEAT.md — Periodic Health Checks

## On Every Heartbeat
1. Check cron job health: `openclaw cron list` — flag any with consecutiveErrors > 0
2. Check disk space: `df -h / | awk 'NR==2 {print $5}'` — alert if >85%
3. Check git sync freshness: `git -C /home/openclaw/.openclaw/workspace log -1 --format=%cr` — alert if >12h
4. Check journal sync: `ls -lt /home/openclaw/.openclaw/workspace/journal/ | head -3` — flag gaps
5. _(Optional)_ Check a custom service URL if configured: `curl -sf {{infra_service_health_url}} > /dev/null`

## Alert Thresholds
- Cron: any job with 3+ consecutive errors → report immediately
- Disk: >85% used → warn, >95% → critical
- Git: last sync >12h ago → warn
- Custom service: down → report (if configured)

## Report Format
If issues found, summarize as:
```
⚠️ Health Check:
- [issue 1]
- [issue 2]
```
If all clear, reply HEARTBEAT_OK.
