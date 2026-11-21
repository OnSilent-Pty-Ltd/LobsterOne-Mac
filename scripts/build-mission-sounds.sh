#!/bin/zsh
# Builds the recorded half of the Mission control and Desk sound sets from public-domain and
# CC0 sources. Downloads into a scratch folder, trims each to the moment that matters, fades
# the ends and evens out the level. The synthesised ones come from make-garry-sounds.py.
#
#   scripts/build-mission-sounds.sh <download-dir> <output-dir>
#
# Sources and rights (checked 18 Nov 2026):
# - NASA mission audio, https://www.nasa.gov/historical-sounds/ : works of US federal
#   employees, no US copyright. NASA's media guidelines: no NASA logos, nothing that implies
#   NASA endorses LobsterOne. Shuttle call-outs are routine, unnamed crew and controllers.
# - NOAA PMEL "Bloop", https://www.pmel.noaa.gov/acoustics/sounds/bloop.html : US federal work.
# - Dial-up handshake, https://commons.wikimedia.org/wiki/File:Dial_up_connection_(short).oga : CC0.
# - Freesound, CC0 (shown on each page): typewriter bell by eZZin (623435), service bell by
#   Squidems (709925), referee whistle by SpliceSound (218318).
# Second batch (same date):
# - NASA Audio Highlight Reels, https://archive.org/details/NasaAudioHighlightReels : NASA JSC,
#   Public Domain Mark. Shuttle launch loops and the Apollo 11 and 13 quotes. The Apollo
#   lines are named astronauts' voices; cut points for those two were set from the loudness
#   envelope, not by ear.
# - Sputnik beep, Saturn radio waves (nasa.gov historical sounds) and Perseverance's Mars
#   microphone (science.nasa.gov, NASA/JPL-Caltech/LANL/CNES/CNRS): NASA media guidelines.
# - Juno bow shock: NASA/JPL-Caltech/SwRI/Univ. of Iowa, via an archive.org mirror of NASA's
#   SoundCloud that states no licence of its own.
# - GW150914 chirp, https://gwosc.org/audio/ : CC BY 4.0, LIGO/GWOSC.
# - V.90 handshake, https://archive.org/details/modem-handshakes-collection : CC BY 4.0, ~peron.
# - Lincolnshire Poacher and RTTY, Wikimedia Commons: public domain, recorded by Oona Räisänen.
# - Boxing bell, https://commons.wikimedia.org/wiki/File:Dingdingding.wav : CC0.
set -euo pipefail
dl=${1:?download dir}; out=${2:?output dir}
mkdir -p "$dl" "$out"
ua="LobsterOneSoundBuild/1.0"

fetch() { [[ -s "$dl/$1" ]] || curl -sSfL -A "$ua" -o "$dl/$1" "$2"; }
nasa=https://www.nasa.gov/wp-content/uploads/2015/01
fetch roger.mp3 $nasa/640170main_Roger20Roll.mp3
fetch computers.mp3 $nasa/640149main_Computers20are20in20Control.mp3
fetch read.mp3 $nasa/639900main_How_do_you_Read.mp3
fetch wheelstop.mp3 $nasa/640174main_Wheel20Stop.mp3
fetch launch.mp3 $nasa/590189main_ringtone_131_launchNats.mp3
fetch bloop.wav https://www.pmel.noaa.gov/acoustics/sounds/bloop.wav
fetch dialup.oga "https://upload.wikimedia.org/wikipedia/commons/8/85/Dial_up_connection_%28short%29.oga"
fetch typewriter.mp3 https://cdn.freesound.org/previews/623/623435_2175308-hq.mp3
fetch servicebell.mp3 https://cdn.freesound.org/previews/709/709925_3199363-hq.mp3
fetch whistle.mp3 https://cdn.freesound.org/previews/218/218318_1480854-hq.mp3

reels=https://archive.org/download/NasaAudioHighlightReels
loop=$reels/Sound-Bite-Space-Shuttle-Launch-Comm
fetch eagle_quote.mp3 $reels/Sound-Bite_Apollo-11_Eagle-has-Landed_Quote.mp3
fetch problem_quote.mp3 $reels/Sound-Bite_Apollo-13_Houston-weve-had-a-problem_Quote.mp3
fetch cdr_go.mp3 ${loop}_UHF-CDR-is-Go.mp3
fetch go_ahead.mp3 ${loop}_UHF-Go-Ahead.mp3
fetch houston_goahead.mp3 ${loop}_UHF-Houston-Go-Ahead.mp3
fetch hack15.mp3 ${loop}_212-15-Second-Hack.mp3
fetch throttle_nasa1.mp3 $nasa/640150main_Go20at20Throttle20Up.mp3
fetch sputnik.mp3 $nasa/578626main_sputnik-beep.mp3
fetch saturn_nasa.mp3 $nasa/584795main_saturn_radio_waves.mp3
mars=https://assets.science.nasa.gov/content/dam/science/psd/mars/downloadable_items/4/5
fetch mars_laser.mp3 $mars/45831_SCAM_MIC_SOL012_RUN001.mp3
fetch mars_wind.wav $mars/45704_1st_Sounds_from_Mars_filters_out_rover_self-noise.wav
fetch juno_bowshock.mp3 "https://archive.org/download/creepy-sounds-recorded-in-space-by-nasa-collection/Juno_%20Crossing%20Jupiter%27s%20Bow%20Shock.mp3"
fetch ligo_tmpl_shift.wav https://gwosc.org/GW150914data/GW150914_template_shifted.wav
fetch modem_v90.wav https://archive.org/download/modem-handshakes-collection/handshakes/xircom-creditcardlan-v90.wav
fetch poacher.ogg https://upload.wikimedia.org/wikipedia/commons/4/4a/Poacher.ogg
fetch rtty.ogg https://upload.wikimedia.org/wikipedia/commons/c/c5/RTTY.ogg
fetch boxing-bell.wav https://upload.wikimedia.org/wikipedia/commons/6/64/Dingdingding.wav

# name  source  start  length  fade-in  fade-out
cut() {
  local name=$1 src=$2 ss=$3 t=$4 fi=$5 fo=$6
  local st=$(( t - fo ))
  local gain=$(ffmpeg -v info -ss $ss -t $t -i "$dl/$src" -af volumedetect -f null - 2>&1 | awk '/max_volume/{print -3 - $5}')
  ffmpeg -v error -y -ss $ss -t $t -i "$dl/$src" -ac 1 -ar 44100 \
    -af "afade=t=in:d=$fi,afade=t=out:st=$st:d=$fo,volume=${gain}dB" -c:a pcm_s16le "$out/$name.wav"
  echo "$name ${t}s (gain ${gain}dB)"
}
cut mission-roger-roll       roger.mp3       0.0  1.49 0.01 0.12
cut mission-how-do-you-read  read.mp3        0.0  1.65 0.01 0.15
cut mission-computers        computers.mp3   0.0  4.18 0.01 0.25
cut mission-wheelstop        wheelstop.mp3   0.2  1.15 0.02 0.12
cut mission-liftoff          launch.mp3      4.0  1.6  0.15 0.5
cut mission-bloop            bloop.wav       2.8  1.6  0.1  0.4
cut mission-dial-up          dialup.oga      1.5  2.0  0.05 0.4
cut desk-typewriter-bell     typewriter.mp3  0.7  0.9  0.005 0.35
cut desk-service-bell        servicebell.mp3 1.35 1.5  0.005 0.6
cut desk-whistle             whistle.mp3     0.05 0.7  0.01 0.15
cut mission-eagle-landed     eagle_quote.mp3     5.15 1.2  0.03 0.12
cut mission-problem          problem_quote.mp3   1.0  2.0  0.03 0.12
cut mission-cdr-go           cdr_go.mp3          0.0  1.56 0.01 0.1
cut mission-go-ahead         go_ahead.mp3        0.0  1.2  0.01 0.1
cut mission-houston-go-ahead houston_goahead.mp3 0.0  1.41 0.01 0.1
cut mission-throttle-up      throttle_nasa1.mp3  0.0  1.6  0.01 0.1
cut mission-t-minus-15       hack15.mp3          0.2  0.68 0.02 0.08
cut space-sputnik            sputnik.mp3         0.65 1.5  0.02 0.1
cut space-saturn             saturn_nasa.mp3     5.0  2.0  0.15 0.5
cut space-mars-laser         mars_laser.mp3      0.9  1.1  0.01 0.1
cut space-mars-wind          mars_wind.wav       6.1  2.0  0.2  0.6
cut space-juno-shock         juno_bowshock.mp3   2.8  1.7  0.05 0.5
cut space-ligo-chirp         ligo_tmpl_shift.wav 0.5  1.5  0.1  0.05
cut signal-modem             modem_v90.wav       4.4  2.0  0.03 0.3
cut signal-numbers-station   poacher.ogg         1.1  2.0  0.05 0.3
cut signal-teletype          rtty.ogg            0.1  1.5  0.02 0.2
cut desk-boxing-bell         boxing-bell.wav     0.0  1.73 0.005 0.2
