#!/bin/bash
# battery-capacity-logger.sh — sample BAT0 every 60s to CSV until stopped.
# This battery exposes charge_* (uAh) not energy_*. Wh = uAh * uV / 1e12.
BAT=/sys/class/power_supply/BAT0
OUT=/home/ethan/battery-test-$(date +%Y%m%d).csv
[ -f "$OUT" ] || echo "timestamp,status,capacity_pct,charge_now_uAh,charge_full_uAh,current_uA,voltage_uV,watts,wh_est" > "$OUT"
echo "logging to $OUT (pid $$)"
while true; do
  ts=$(date +%s)
  st=$(cat $BAT/status 2>/dev/null)
  cap=$(cat $BAT/capacity 2>/dev/null)
  cn=$(cat $BAT/charge_now 2>/dev/null)
  cf=$(cat $BAT/charge_full 2>/dev/null)
  cur=$(cat $BAT/current_now 2>/dev/null)
  vol=$(cat $BAT/voltage_now 2>/dev/null)
  w=""; wh=""
  if [ -n "$cur" ] && [ -n "$vol" ] && [ "$cur" != "0" ] && [ "$cur" != "" ]; then
    w=$(python3 -c "print(round($cur*$vol/1e12,3))" 2>/dev/null)
  fi
  if [ -n "$cn" ] && [ -n "$vol" ]; then
    wh=$(python3 -c "print(round($cn*$vol/1e12,3))" 2>/dev/null)
  fi
  echo "$ts,$st,$cap,$cn,$cf,$cur,$vol,$w,$wh" >> "$OUT"
  sleep 60
done