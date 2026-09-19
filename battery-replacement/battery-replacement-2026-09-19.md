# Battery Replacement & Capacity Test — 2026-09-19

Companion to [../ssd/migration-log-2026-09-13.md](../ssd/migration-log-2026-09-13.md) and [../linux/README.md](../linux/README.md). Records the battery replacement on the HP Pavilion 15-cc6xx, the verification of the new cell, and a full discharge capacity test with real delivered-energy measurement.

---

## 1. Background

| Battery | Reported design | Reality |
|---|---|---|
| Old (original) | **15.5 Wh** — misreported/broken gauge; real-world runtime < 3 h | End of life |
| New (third-party, HP "Primary" profile) | **43.98 Wh** (3808 mAh @ 11.55 V), 0 cycles | Tested below |

- **BIOS reset gotcha**: battery swaps pull the EC/CMOS on this machine → BIOS reverts to defaults, which **re-enabled Secure Boot** and broke the unsigned Limine bootloader until re-disabled in F10. Check F10 for any other settings after future battery work. (Boot hardening proved itself here: even with reset NVRAM, the disabled HDD ESP meant the machine could only boot the SSD.)
- New battery exposes proper HP data (0 cycle count, sane voltages, correct design capacity) — unlike the old one.

## 2. Health checks (out of the box)

| Check | Value |
|---|---|
| `charge_full_design` | 3808 mAh (43.98 Wh) |
| `charge_full` at first full | **recalibrated by EC to 3712 mAh (42.87 Wh)** — gauge learning at first 100%, ~97.5% of design |
| Cycle count | 0 |
| Charging behavior | Normal CC/CV (13.0–13.2 V during charge, 11.55 V nominal) |

## 3. Capacity test methodology

The EC on this battery has quirks: `current_now` and the hwmon `curr1_input` are unreliable (blank/nonsense), so live `V×I` sampling is impossible. Instead the test uses **coulomb counting**: the battery IC's `charge_now` register (accurate to ~1–2%) is integrated against live voltage:

```
delivered Wh = Σ (Δcharge_now_µAh × V_sample_µV) / 10¹²
```

This measures *actual energy delivered*, independent of the gauge's full-capacity claim — i.e. it validates the gauge itself, which matters because the old battery's gauge lied about capacity too.

- Logger: [battery-capacity-logger.sh](battery-capacity-logger.sh) — 60 s samples to CSV
- Raw data: [battery-test-2026-09-19.csv](battery-test-2026-09-19.csv) (282 samples, one continuous discharge 11:15–15:57)

## 4. Results

| Metric | Value |
|---|---|
| Discharge run | 100% → 10%, **215 min** |
| Energy delivered (coulomb integral) | **37.24 Wh** |
| Average draw | 10.37 W (active use: Firefox + 2 Electron apps + agent session, 30% backlight) |
| Remaining at 10% (nominal V) | 4.44 Wh |
| **Estimated true capacity** | **≈ 41.7 Wh** |
| Gauge claim (42.87 Wh) | **97.2% agreement** — honest within ~3% |
| vs 43.98 Wh nameplate | ~95% health |

Linearity check: gauge consumed 90% of its span while physics delivered 37.24 Wh → 41.4 Wh per 100% span — consistent throughout, no non-linear collapse region.

**Verdict: genuine ~42 Wh cell.** For contrast: the old battery's claimed 15.5 Wh (had it been real) would have died in ~1.5 h at this draw.

## 5. Practical runtime (at ~42 Wh)

| Scenario | Draw | Runtime |
|---|---|---|
| Active dev workload (this test) | ~10.4 W | ~4 h |
| Light use, lower brightness | ~6 W | ~7 h |
| With WiFi powersave re-enabled (pending) | −0.5–0.8 W | +45–60 min |
| With HDD parked in standby | already included | ~0.15 W vs 1.2 W spinning |

Draw breakdown at the observed 10.4 W: CPU/SoC ~4–5 W (workload-dependent, Electron-heavy), display ~2.5–3 W @ 30% backlight, platform ~2–2.5 W, WiFi ~0.8 W (powersave off — anti-freeze mitigation, first candidate to re-enable per README §4.1), HDD ~0.15 W.

## 6. Open items

1. **WiFi powersave re-enable** — designated first graduated step: `wifi.powersave = 3` in `/etc/NetworkManager/conf.d/wifi-powersave-off.conf`, restart NM, verify `iw dev wlan0 get power_save` → on. Watch for freeze recurrence per the graduated plan.
2. One more full charge/discharge cycle would settle the gauge further (EC already learned once at first full).
3. Logger left in place (`~/battery-capacity-logger.sh`, logging to `~/battery-test-*.csv`) — stop with `pkill -f battery-capacity-logger` when done collecting.
