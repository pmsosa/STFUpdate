#!/bin/zsh
# Tests for the thaw logic. Runs the real script against a fake `brew` and a throwaway $HOME,
# so nothing on this machine is touched. Usage: tests/run.sh
emulate -L zsh
setopt pipe_fail

ROOT=${0:A:h:h}
SCRIPT=$ROOT/update-or-stfu
pass=0; fail=0

# fresh sandbox per test: fake HOME, fake brew on PATH
setup() {
  T=$(mktemp -d)
  export HOME=$T/home; mkdir -p $HOME/.config/update-or-stfu $T/bin
  export CALLS=$T/calls; : > $CALLS
  cat > $T/bin/brew <<'BREW'
#!/bin/zsh
case $1 in
  update) exit 0 ;;
  cleanup) exit 0 ;;
  outdated)
    if [[ " $* " == *" --cask "* ]]; then print -rl -- "${(@s:,:)FAKE_CASKS}"; else print -rl -- "${(@s:,:)FAKE_FORMULAE}"; fi | grep . ;;
  upgrade)
    name=${@[-1]}
    [[ ,$FAKE_FAIL, == *,$name,* ]] && exit 1
    print -- $name >> $CALLS ;;
esac
exit 0
BREW
  chmod +x $T/bin/brew
  export PATH=$T/bin:/usr/bin:/bin:/usr/sbin:/sbin
  unset FAKE_FAIL
  export FAKE_FORMULAE="" FAKE_CASKS=""
  cat > $HOME/.config/update-or-stfu/config <<CONF
THAW_DAYS=7
NO_THAW=(docker)
SKIP=()
DOCKER_SKIP_IF_RUNNING=0
GREEDY_CASKS=0
USE_MAS=0
NOTIFY=0
CONF
  SEEN=$HOME/.local/state/update-or-stfu/seen.tsv
  NEEDS=$HOME/.local/state/update-or-stfu/needs-you.tsv
  mkdir -p ${SEEN:h}
}

# seed a version as first seen N days ago
seed() { printf 'formula\t%s\t%s\t%s\n' $1 $2 $(( $(date +%s) - $3 * 86400 )) >> $SEEN; }
no() { ! "$@" }
ran() { grep -qx $1 $CALLS }
check() { # check "description" command...  (use `no` to negate)
  local d=$1; shift
  if "$@"; then pass=$((pass+1)); print "  ok   $d"; else fail=$((fail+1)); print "  FAIL $d"; fi
}
run() { zsh $SCRIPT run "$@" >/dev/null 2>&1 }

print "new version is held (thaw), not installed"
setup; FAKE_FORMULAE="wget (1.0) < 1.1"; run
check "wget not upgraded" no ran wget
check "wget tracked in seen.tsv" grep -q 'wget' $SEEN

print "version seen for >= THAW_DAYS is installed"
setup; FAKE_FORMULAE="wget (1.0) < 1.1"; seed wget 1.1 8; run
check "wget upgraded" ran wget
check "wget dropped from seen.tsv" no grep -q wget $SEEN

print "version seen for fewer days than THAW_DAYS is still held"
setup; FAKE_FORMULAE="wget (1.0) < 1.1"; seed wget 1.1 6; run
check "wget not upgraded" no ran wget

print "a newer version restarts the clock"
setup; FAKE_FORMULAE="wget (1.0) < 1.2"; seed wget 1.1 30; run
check "wget 1.2 not upgraded (only 1.1 was old)" no ran wget

print "NO_THAW packages install immediately"
setup; FAKE_FORMULAE="docker (1) < 2"; run
check "docker upgraded at once" ran docker

print "SKIP packages are never upgraded"
setup; sed -i '' 's/^SKIP=.*/SKIP=(wget)/' $HOME/.config/update-or-stfu/config
FAKE_FORMULAE="wget (1.0) < 1.1"; seed wget 1.1 30; run
check "wget skipped" no ran wget

print -- "--dry-run changes nothing"
setup; FAKE_FORMULAE="wget (1.0) < 1.1"; seed wget 1.1 30; run --dry-run
check "wget not upgraded" no ran wget
check "wget still tracked" grep -q wget $SEEN

print "casks are checked too"
setup; FAKE_CASKS="firefox (1) < 2"; printf 'cask\tfirefox\t2\t%s\n' $(( $(date +%s) - 10*86400 )) >> $SEEN; run
check "firefox upgraded" ran firefox

print "failed upgrade goes to needs-you and is not retried"
setup; FAKE_FORMULAE="wget (1.0) < 1.1"; seed wget 1.1 30; FAKE_FAIL=wget run
check "wget in needs-you" grep -q wget $NEEDS
FAKE_FAIL= ; run
check "not retried on the next run" no ran wget

print "clear forgets an entry"
zsh $SCRIPT clear formula wget >/dev/null 2>&1
check "needs-you emptied" no grep -q wget $NEEDS

print -- "--version"
check "prints a version" zsh -c "[[ \$(zsh $SCRIPT --version) == update-or-stfu\ * ]]"

print "install migrates the pre-1.0 agent labels (launchctl is faked)"
setup
cat > $T/bin/launchctl <<'LC'
#!/bin/zsh
print -r -- "$*" >> $LCALLS
[[ $1 == print ]] && exit 1
exit 0
LC
chmod +x $T/bin/launchctl; export LCALLS=$T/launchctl.calls; : > $LCALLS
LA=$HOME/Library/LaunchAgents; mkdir -p $LA
for l in com.user.update-or-stfu com.user.update-or-stfu.app; do : > $LA/$l.plist; done
zsh $SCRIPT install >/dev/null 2>&1
check "legacy scheduler plist removed" no test -e $LA/com.user.update-or-stfu.plist
check "legacy app plist removed" no test -e $LA/com.user.update-or-stfu.app.plist
check "new scheduler plist written" test -f $LA/com.konukoii.update-or-stfu.plist
check "new agent bootstrapped" grep -q 'bootstrap .*com.konukoii.update-or-stfu.plist' $LCALLS
check "old agent booted out" grep -q 'bootout .*com.user.update-or-stfu.plist' $LCALLS
check "existing config left alone" grep -q 'THAW_DAYS=7' $HOME/.config/update-or-stfu/config

print "\n$pass passed, $fail failed"
(( fail == 0 ))
