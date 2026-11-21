#!/bin/zsh
# Builds the Soldier (Tiberian Dawn) and Red Alert sets from candidate files gathered on
# 18 Nov 2026 (see sound-candidates/cnc/*/MANIFEST.md for each line's source).
#
#   scripts/build-soldier-sounds.sh <candidates-dir> <output-dir>
#
# Rights: Command & Conquer and Red Alert audio is Westwood/EA's. Tiberian Dawn lines were
# decoded from the 2007 freeware release (as mirrored by OpenRA); Red Alert lines come from fan
# soundboards and repos. None is licensed to LobsterOne; bundled at the founder's decision.
set -euo pipefail
src=${1:?candidates dir}; out=${2:?output dir}
mkdir -p "$out"
td=$src/tiberian; ra=$src/red-alert

# name  source-file
clip() {
  local name=$1 file=$2
  local tmp=$out/.tmp.wav
  ffmpeg -v error -y -i "$file" -ac 1 -ar 44100 \
    -af "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.01,areverse,silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.02,areverse" "$tmp"
  local d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp")
  local gain=$(ffmpeg -v info -i "$tmp" -af volumedetect -f null - 2>&1 | awk '/max_volume/{print -3 - $5}')
  local st=$(awk -v d=$d 'BEGIN{print (d>0.05)?d-0.04:0}')
  ffmpeg -v error -y -i "$tmp" -t 2.1 -af "afade=t=in:d=0.005,afade=t=out:st=$st:d=0.04,volume=${gain}dB" -c:a pcm_s16le "$out/$name.wav"
  rm -f "$tmp"; printf "%-22s %.2fs\n" $name $d
}

# Soldier: more takes in the families your own clips started (classic-hello, classic-on-it).
clip classic-hello-4      $td/td-start-reporting.wav
clip classic-hello-5      $td/td-start-ready-and-waiting.wav
clip classic-on-it-3      $td/td-plan-you-got-it-commando.wav
clip classic-on-it-4      $td/td-plan-acknowledged.wav
clip classic-on-it-5      $td/td-plan-right-away-sir.wav
clip classic-on-it-6      $td/td-plan-roger.wav
clip classic-yes-1        $td/td-permission-commander-mobius.wav
clip classic-yes-2        $td/td-permission-yes-mobius.wav
clip classic-yes-3        $td/td-permission-cmon-commando.wav
clip classic-ready-1      $td/td-waiting-unit-ready.wav
clip classic-ready-2      $td/td-waiting-reinforcements-arrived.wav
clip classic-ready-3      $td/td-waiting-keep-em-comin-commando.wav
clip classic-done-1       $td/td-finished-construction-complete.wav
clip classic-done-2       $td/td-finished-mission-accomplished.wav
clip classic-done-3       $td/td-finished-present-for-ya-commando.wav

# Red Alert 1 and 2.
clip redalert-start-1     $ra/ra2-start-battle-control-online.wav
clip redalert-start-2     $ra/ra2-start-conscript-reporting.wav
clip redalert-start-3     $ra/ra1-start-reporting.wav
clip redalert-kirov       $ra/ra2-start-kirov-reporting.wav
clip redalert-orders-1    $ra/ra1-permission-awaiting-orders.wav
clip redalert-orders-2    $ra/ra2-permission-waiting-orders.wav
clip redalert-orders-3    $ra/ra2-permission-orders-comrade.wav
clip redalert-orders-4    $ra/ra2-permission-assignment-sir.wav
clip redalert-ready-1     $ra/ra2-waiting-unit-ready.wav
clip redalert-ready-2     $ra/ra2-waiting-standing-by.wav
clip redalert-ready-3     $ra/ra2-waiting-reinforcements-arrived.wav
clip redalert-done-1      $ra/ra2-finished-construction-complete.wav
clip redalert-done-2      $ra/ra2-finished-unit-promoted.wav
clip redalert-done-3      $ra/ra1-finished-mission-accomplished.wav
clip redalert-plan-1      $ra/ra2-plan-acknowledged.wav
clip redalert-plan-2      $ra/ra2-plan-moving-out.wav
clip redalert-plan-3      $ra/ra2-plan-on-my-way.wav
clip redalert-plan-4      $ra/ra1-plan-affirmative.wav
clip redalert-funds       $ra/ra2-permission-insufficient-funds.wav
