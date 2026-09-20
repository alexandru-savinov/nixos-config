```sh
# PENDING: owner deployment and live acceptance have not been performed.
# Run on each deployed host; choose expected=10 on rpi5 after private activation,
# or expected=9 on choir after delivery activation (7/8 before those gates).
expected=9
systemctl is-active vigil.timer vigil-tick.socket
systemctl list-timers vigil.timer --no-pager
sudo systemctl start vigil.service
systemctl show vigil.service -p Result -p ExecMainStatus
sudo jq -e --argjson expected "$expected" \
  '(.verde + .picat + .necitit) == $expected and .necitit == 0' /var/lib/vigil/tick
run_id=$(sudo jq -r .run_id /var/lib/vigil/tick)
sudo journalctl _SYSTEMD_INVOCATION_ID="$run_id" -o cat --no-pager
test "$(( $(date +%s) - $(sudo stat -c %Y /var/lib/vigil/last-channel-ok) ))" -lt 172800

# From choir, inspect rpi5's tick.
curl --fail --max-time 10 http://100.106.93.87:8747/ | jq -e '
  (.la | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t |
  $t <= now and $t > (now - 900)'

# From rpi5, inspect choir's tick.
curl --fail --max-time 10 http://100.94.191.54:8747/ | jq -e '
  (.la | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t |
  $t <= now and $t > (now - 900)'

# Isolated acknowledgement acceptance on either host; fake Telegram only.
sudo systemd-run --unit=vigil-ack-acceptance --wait --collect \
  --property=User=vigil --property=PrivateTmp=yes \
  /run/current-system/sw/bin/vigil autoproba --ack-only

# PENDING: live acknowledgement, only after a natural NECITIT notification.
# Replace this with its generic contract name, never a private entity/device ID.
contract=replace-with-generic-contract-name
sudo test -f "/var/lib/vigil/nota-sent/$contract"
sudo touch "/var/lib/vigil/ack/$contract"
sudo systemctl start vigil.service
sudo test ! -e "/var/lib/vigil/ack/$contract"
run_id=$(sudo jq -r .run_id /var/lib/vigil/tick)
sudo journalctl _SYSTEMD_INVOCATION_ID="$run_id" -o cat --no-pager
# Observe the next threshold crossing and exactly one new NECITIT notification.

# PENDING: first real incident delivery date. Do not substitute the gallery test.
# After a real incident reaches Telegram, record its observed date here.
# Plan 2 starts from that evidence; no date has been recorded yet.
```
