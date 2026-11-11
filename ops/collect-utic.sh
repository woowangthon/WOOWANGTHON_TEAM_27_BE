#!/usr/bin/env bash
set -euo pipefail
umask 077
cd /opt/liferadar/WOOWANGTHON_TEAM_27_BE
# EnvironmentFile is supplied by systemd; never shell trace or echo credentials.
exec flock -n /var/lib/liferadar/utic-collector.lock /opt/liferadar/bin/collect-utic
